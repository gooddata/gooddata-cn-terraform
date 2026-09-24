# The ticket step: bundle, template, destination

Used when a family lands in "Needs a GoodData support ticket" or the user has
exhausted the self-fixes. Three parts, in order.

## 1. Collect a support bundle

`scripts/support-bundle.yaml` is a troubleshoot.sh spec that gathers cluster
info, the Helm values and manifests of the `gooddata-cn` and `pulsar`
releases, the objects in the `gooddata-cn`, `pulsar`, `ingress-nginx`, and
`cert-manager` namespaces, and the last day of logs from each. It only reads
from the cluster and writes one archive to the current directory.

Check for the collector, then run it from the repo root:

```bash
kubectl support-bundle --help >/dev/null 2>&1 && echo "collector present" || echo "install it: https://troubleshoot.sh/docs/"
kubectl support-bundle scripts/support-bundle.yaml
```

Installation is `kubectl krew install support-bundle` or a binary from the
troubleshoot.sh site. The archive is named `support-bundle-<timestamp>.tar.gz`.
Tell the user two things before they share it: the spec redacts common secret
patterns from Helm values, but the archive still describes their whole
deployment, so it goes to GoodData through the support channel only; and with
`ingress_controller` set to `alb` or `istio_gateway` the ingress log selector in
the spec matches nothing, which is fine.

When the collector cannot be installed, gather the same material by hand into a
directory the user then compresses:

```bash
mkdir -p gdcn-support && cd gdcn-support
kubectl cluster-info dump --namespaces gooddata-cn,pulsar,ingress-nginx,cert-manager --output-directory=cluster-dump
helm get values gooddata-cn -n gooddata-cn > helm-values-gooddata-cn.yaml
helm history gooddata-cn -n gooddata-cn > helm-history-gooddata-cn.txt
helm get values pulsar -n pulsar > helm-values-pulsar.yaml
kubectl get events -A --sort-by=.lastTimestamp > events.txt
```

Warn the user that `helm get values` output contains every value the release
was installed with, including credentials, and must be reviewed before sharing.

## 2. Fill the ticket template

Fill every field from the checks already run; do not ask the user for anything
you already know.

```
Deployment: <aws | azure | local>, size_profile <value>, gooddata-cn chart <helm_gdcn_version>
Ingress: <ingress_controller> with <tls_mode>, DNS <dns_provider>
Observability: <on | off>
Symptom: <one sentence, the user's words>
Started: <when, and what changed right before>
Family followed: <A to G, reference name>
Checks run and results:
  - <check>: <result>
  - ...
Fixes tried and outcome:
  - <fix>: <did not help | partially helped>
Support bundle: <filename>
```

Quote variable names, never values of secrets; quote log lines only with tokens
and connection strings removed.

## 3. Send it

The README says it plainly: reach out to your GoodData contact. Customers with
a support portal login open the ticket at https://support.gooddata.com/ and
attach the bundle there. Suggest a title that names the component and the
symptom, for example "metadata-api CrashLoopBackOff after upgrade to 4.13.2".

Once the ticket is out, stop diagnosing. Re-running the same checks does not
change the answer, and the transcript of what was tried is already in the
ticket.
