# Family D: login, users, organizations, license

Users cannot log in, `scripts/create-user.sh` fails, an Organization is stuck,
or logs mention the license. Terraform creates the organizations from
`gdcn_orgs`, stores each admin's bootstrap credentials in the secret
`gdcn-org-admin-<id>`, and stores the license in the secret `gdcn-license`.
Dex is the built-in identity provider on `auth_hostname`; an external OIDC
provider is configured outside Terraform.

## Check these first

1. **Organizations and their state.**
   ```bash
   kubectl get organization -n gooddata-cn
   kubectl describe organization <id>-org -n gooddata-cn | sed -n '/Status/,$p'
   ```
   The Organization is named `<id>-org`. Its status conditions and the
   organization controller log explain a not-ready state:
   ```bash
   kubectl logs -n gooddata-cn deploy/gooddata-cn-organization-controller --tail=100
   ```
2. **The secrets exist** (existence only, never the contents).
   ```bash
   kubectl get secret gdcn-license gdcn-org-admin-<id> -n gooddata-cn
   ```
3. **License acceptance.** The metadata API validates the license at start.
   ```bash
   kubectl logs -n gooddata-cn deploy/gooddata-cn-metadata-api --tail=300 | grep -i -E 'licen[cs]e'
   ```
   Lines about an invalid, expired, or missing license, or an entitlement that
   is not included, are the diagnosis. AI features and AI Lake need their own
   entitlements.
4. **Dex and the auth service.**
   ```bash
   kubectl get pods -n gooddata-cn | grep -E 'dex|auth-service'
   kubectl logs -n gooddata-cn deploy/gooddata-cn-dex --tail=100
   kubectl logs -n gooddata-cn deploy/gooddata-cn-auth-service --tail=100
   ```
5. **The auth hostname resolves and answers.** A login page that never appears
   is family A for `auth_hostname`, not an authentication fault:
   ```bash
   curl -kIs https://<auth_hostname>/dex/.well-known/openid-configuration
   ```

## You can fix this yourself

Gated, one at a time:

- **`create-user.sh` says 401 or "unauthorized" on the bootstrap call.** The
  admin secret and the Organization's admin token no longer match, typically
  after the Organization was recreated by hand. Re-run `terraform apply` through
  the saved-plan flow; it restores both from state. Then the user re-runs the
  script.
- **`create-user.sh` cannot find outputs.** It must run from inside the
  environment directory (`aws/`, `azure/`, or `local/`), where `terraform
  output` works.
- **User exists in Dex but cannot log in.** The script reuses an existing Dex
  identity and re-creates the GoodData.CN user entity; run it again with the
  same email and let it repair the mapping.
- **License invalid or expired.** The user gets a current key from their
  GoodData contact, replaces the value of `gdcn_license_key` in
  `settings.tfvars` themselves, and you plan and apply. If someone edited the
  `gdcn-license` secret by hand, a plain re-apply restores it from the tfvars
  value; the metadata API picks up the new key on its next restart, which the
  apply triggers.
- **External OIDC misconfiguration.** Not managed by this repo. Point at
  https://www.gooddata.com/docs/cloud-native/latest/manage-organization/set-up-authentication/
  and check that the issuer URL, client ID, and redirect URI in the provider
  match the organization settings there.
- **Organization stuck Terminating.** The Organization carries a finalizer that
  only a running organization controller can clear. First make the controller
  pod healthy (family B) and wait: a healthy controller clears it within a
  minute. Only when the controller is gone for good (the release was
  uninstalled, or the cluster is being torn down) and the object stays
  Terminating, remove the finalizer by hand. This is the most consequential
  command in this skill; state it in full and wait for an explicit yes:
  ```bash
  kubectl patch organization <id>-org -n gooddata-cn --type=merge -p '{"metadata":{"finalizers":null}}'
  ```

## Needs a GoodData support ticket

- The license is current, the secret exists, and the metadata API still logs an
  entitlement or validation error.
- Dex and the auth service are Running with clean logs, the auth hostname
  answers, and every login still fails.
- An Organization stays not-ready with a controller error that names no
  external cause.

Do not re-run `create-user.sh` again at this point; capture its output instead.

## What to include

`kubectl get organization -n gooddata-cn`, the `describe` status of the
affected Organization, the controller, Dex, auth-service, and metadata-api log
tails with tokens removed, the exact `create-user.sh` output if used, and the
`auth_hostname` value.

## Deeper investigation (observability on)

Dashboard section 2 (API request rate by upstream): a 4xx surge on one upstream
is a client or auth problem rather than a platform fault. In Loki:

```
{namespace="gooddata-cn", container=~".*(dex|auth-service|metadata-api).*"} |~ "(?i)(unauthori|licen[cs]e|token)"
```

## See also

- Family A when the auth hostname does not resolve or the certificate is wrong.
- The `install-gdcn` skill, step 9, for the two first-user paths.
