#!/usr/bin/env python3
"""Regression tests for structure_diff.normalize.

The script's contract is that no value ever reaches the output. These tests
pin the cases that previously leaked: nested collections, openers carrying a
trailing comment, and brackets or hashes inside string values.

Run: python3 .claude/skills/sync-settings-tfvars/scripts/test_structure_diff.py
"""

import unittest
from pathlib import Path

import sys

sys.path.insert(0, str(Path(__file__).parent))

from structure_diff import incomplete, new_state, normalize, scan_line, split_code_and_comment


def depth_after(*lines):
    st = new_state()
    for line in lines:
        scan_line(line, st)
    return st

SECRET = "SHOULD_NEVER_APPEAR"


def run(text):
    lines, names = normalize(text)
    return "\n".join(lines), names


class NoValueLeaks(unittest.TestCase):
    def assertRedacted(self, text):
        out, _ = run(text)
        self.assertNotIn(SECRET, out, f"value leaked into output:\n{out}")

    def test_simple_assignment(self):
        self.assertRedacted(f'key = "{SECRET}"')

    def test_nested_map(self):
        self.assertRedacted(
            f'outer = {{\n  inner = {{\n    tok = "{SECRET}"\n  }}\n  after = "{SECRET}"\n}}\n'
        )

    def test_nested_list(self):
        self.assertRedacted(f'outer = [\n  [\n    "{SECRET}",\n  ],\n  "{SECRET}",\n]\n')

    def test_list_of_maps(self):
        self.assertRedacted(f'orgs = [\n  {{\n    id = "{SECRET}"\n  }},\n]\n')

    def test_opener_with_trailing_comment(self):
        self.assertRedacted(f'items = [ # note\n  "{SECRET}",\n]\n')

    def test_map_opener_with_trailing_comment(self):
        self.assertRedacted(f'm = {{ # note\n  k = "{SECRET}"\n}}\n')

    def test_quoted_keys(self):
        self.assertRedacted(f'm = {{\n  "dotted.key" = "{SECRET}"\n}}\n')

    def test_heredoc(self):
        self.assertRedacted(f"body = <<EOT\n{SECRET}\nEOT\n")

    def test_commented_out_block(self):
        self.assertRedacted(f'# m = {{\n#   k = "{SECRET}"\n# }}\n')

    def test_bracket_inside_string_does_not_end_block(self):
        self.assertRedacted(f'm = {{\n  a = "has_a_]_bracket"\n  b = "{SECRET}"\n}}\n')

    def test_hash_inside_string_is_not_a_comment(self):
        self.assertRedacted(f'm = {{\n  a = "has_a_#_hash"\n  b = "{SECRET}"\n}}\n')

    def test_inline_function_call(self):
        self.assertRedacted(f'v = merge(\n  {{ k = "{SECRET}" }},\n)\n')

    def test_heredoc_body_containing_commented_terminator(self):
        self.assertRedacted(f"body = <<EOT\n# EOT\n{SECRET}\nEOT\n")

    # An indented terminator does close a `<<EOT` heredoc — verified against
    # Terraform 1.15.6 — so `line.strip()` is the correct comparison here.

    def test_indent_marker_heredoc(self):
        self.assertRedacted(f"body = <<-EOT\n  {SECRET}\n  EOT\n")

    def test_heredoc_inside_collection_with_bracket_in_body(self):
        self.assertRedacted(f'm = {{\n  k = <<EOT\n  ]\n  }}\n  EOT\n  s = "{SECRET}"\n}}\n')

    def test_block_comment_with_bracket_inside_collection(self):
        self.assertRedacted(f'm = {{\n  /* note ] and }} */\n  k = "{SECRET}"\n}}\n')

    def test_multi_line_block_comment_inside_collection(self):
        self.assertRedacted(f'm = {{\n  /* line one\n     line two ] */\n  k = "{SECRET}"\n}}\n')

    def test_commented_out_heredoc(self):
        self.assertRedacted(f"# body = <<EOT\n# {SECRET}\n# EOT\n")

    def test_hyphenated_identifier(self):
        self.assertRedacted(f'my-var = "{SECRET}"')

    def test_uppercase_identifier(self):
        self.assertRedacted(f'MyVar = "{SECRET}"')

    def test_non_ascii_identifier(self):
        self.assertRedacted(f'café_var = "{SECRET}"')

    def test_slash_commented_assignment(self):
        self.assertRedacted(f'// api_token = "{SECRET}"')

    def test_slash_commented_block(self):
        self.assertRedacted(f'// m = {{\n//   k = "{SECRET}"\n// }}\n')

    def test_slash_commented_heredoc(self):
        self.assertRedacted(f"// body = <<EOT\n// {SECRET}\n// EOT\n")

    def test_unparsed_assignment_is_still_redacted(self):
        # Backstop for anything the identifier pattern does not recognise.
        self.assertRedacted(f'"odd.key" = "{SECRET}"')
        self.assertRedacted(f'123bad = "{SECRET}"')


class StructureIsPreserved(unittest.TestCase):
    def test_trailing_comment_survives(self):
        out, _ = run('enable = true # kept on deliberately')
        self.assertEqual(out, "enable = <value> # kept on deliberately")

    def test_commented_assignment_keeps_its_hash(self):
        out, _ = run("# enable = true")
        self.assertEqual(out, "# enable = <value>")

    def test_commented_assignment_keeps_its_slashes(self):
        out, _ = run("// enable = true")
        self.assertEqual(out, "// enable = <value>")

    def test_slash_comment_line_passes_through(self):
        out, _ = run("// a standalone note\nk = 1")
        self.assertEqual(out, "// a standalone note\nk = <value>")

    def test_nested_keys_are_not_reported_as_variables(self):
        _, names = run('outer = {\n  inner = {\n    tok = "x"\n  }\n  after = "y"\n}\n')
        self.assertEqual([n for n, _ in names], ["outer"])

    def test_set_versus_commented_is_tracked(self):
        _, names = run('a = 1\n# b = 2\n')
        self.assertEqual(names, [("a", True), ("b", False)])

    def test_plain_comment_lines_pass_through(self):
        out, _ = run("# a standalone note\nk = 1")
        self.assertEqual(out, "# a standalone note\nk = <value>")

    def test_sibling_after_nested_block_still_seen(self):
        _, names = run('outer = {\n  inner = {\n    k = "x"\n  }\n}\nsibling = 1\n')
        self.assertEqual([n for n, _ in names], ["outer", "sibling"])


class Helpers(unittest.TestCase):
    def test_split_respects_quotes(self):
        self.assertEqual(split_code_and_comment('"a#b" # c'), ('"a#b" ', "# c"))

    def test_split_handles_double_slash(self):
        self.assertEqual(split_code_and_comment("1 // c"), ("1 ", "// c"))

    def test_split_handles_escaped_quote(self):
        self.assertEqual(split_code_and_comment(r'"a\"#b"'), (r'"a\"#b"', ""))

    def test_depth_ignores_brackets_in_strings(self):
        self.assertEqual(depth_after('"[[["')["depth"], 0)
        self.assertEqual(depth_after("[{")["depth"], 2)
        self.assertEqual(depth_after("}]")["depth"], -2)

    def test_heredoc_state_survives_until_terminator(self):
        st = depth_after("x = <<EOT", "# EOT", "]")
        self.assertEqual(st["heredoc"], "EOT")
        self.assertTrue(incomplete(st))
        scan_line("EOT", st)
        self.assertIsNone(st["heredoc"])
        self.assertFalse(incomplete(st))

    def test_block_comment_spans_lines(self):
        st = depth_after("m = {", "/* ] } ")
        self.assertTrue(st["block"])
        scan_line("*/", st)
        self.assertFalse(st["block"])
        self.assertEqual(st["depth"], 1)

    def test_bracket_in_heredoc_does_not_change_depth(self):
        st = depth_after("m = {", "k = <<EOT", "]", "}", "EOT")
        self.assertEqual(st["depth"], 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
