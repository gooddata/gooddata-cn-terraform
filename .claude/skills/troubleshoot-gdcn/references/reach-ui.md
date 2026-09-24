# Family A: cannot reach the UI

The organization URL or the login page does not load, or the browser complains
about the certificate. Nearly every case is DNS, TLS issuance, or an unhealthy
ingress path. Read `ingress_controller` first; each check below names the path
it applies to.

## Check these first

1. **Which hostnames and which path.**
   ```bash
   terraform output org_domains
   terraform output auth_hostname
   terraform output ingress_controller     # AWS; elsewhere read settings.tfvars
   ```
   The auth hostname is separate from the organization hostname, and the login
   page redirects to it. If the organization loads but the login page does not,
   the auth hostname is the one to chase.
2. **DNS resolves to the load balancer.**
   ```bash
   dig +short <org_hostname>
   dig +short <auth_hostname>
   ```
   Expected: AWS `alb` and `ingress-nginx` give a load balancer DNS name or its
   addresses; Azure gives the ingress IP; local gives `127.0.0.1` for
   `*.localhost` names without any hosts entry. Empty output means the record is
   missing. Compare against what Terraform expects:
   ```bash
   terraform output manual_dns_records      # self-managed DNS on AWS or Azure
   terraform output hosts_file_entries      # local, non-.localhost names only
   ```
3. **What the endpoint answers.**
   ```bash
   curl -kvI https://<org_hostname>
   ```
   Read three things: whether the TCP connect succeeds, whether the TLS
   handshake completes, and the HTTP status. Healthy is 200 or a 302 to the auth
   hostname. Inside a Dev Container on local, add
   `--connect-to <org_hostname>:443:host.docker.internal:443`.
4. **Ingress objects exist and have an address.**
   ```bash
   kubectl get ingress -A                    # alb and ingress-nginx
   kubectl get gateway,virtualservice -A     # istio_gateway
   ```
   An Ingress with an empty ADDRESS column on AWS `alb` means the load balancer
   controller has not created the ALB yet, or refused to.
5. **Certificate state.**
   - `alb`: the certificate lives in ACM. `terraform output
     acm_validation_records` lists CNAMEs the user must create when DNS is
     self-managed; until they resolve the certificate stays pending and HTTPS
     fails while HTTP may work.
   - `ingress-nginx` and `istio_gateway`: cert-manager issues it.
     ```bash
     kubectl get certificate,certificaterequest,order,challenge -A
     kubectl describe challenge -A | grep -A3 -i reason
     ```
     A challenge stuck pending with a reason mentioning the ACME server not
     reaching the host means public DNS does not point at the ingress yet, or
     port 80 is blocked in front of it.
   - local: the certificate is self-signed on purpose; the browser warning and
     `curl -k` are expected, not a fault.
6. **Controller health for the path.**
   ```bash
   kubectl -n aws-load-balancer-controller get deploy aws-load-balancer-controller   # alb
   kubectl -n aws-load-balancer-controller logs deploy/aws-load-balancer-controller --tail=100
   kubectl -n ingress-nginx get pods,svc                                # ingress-nginx
   kubectl -n istio-ingress get pods,svc                                # istio_gateway
   ```
   On `ingress-nginx` and `istio_gateway`, the Service must have an EXTERNAL-IP;
   `<pending>` for more than a few minutes on a cloud is a quota or subnet-tag
   problem visible in `kubectl describe svc`. On AWS `alb`, subnet tags from the
   README "Use an existing VPC" section are the usual cause of a controller
   error such as "couldn't auto-discover subnets".

## You can fix this yourself

- **Missing or wrong DNS records.** The user creates the records from
  `manual_dns_records` (and `acm_validation_records` for ACM) in their DNS
  provider, then waits for propagation; re-run step 2 until it resolves. Nothing
  in the cluster needs to change.
- **Local name does not resolve from where the command runs.** Inside a Dev
  Container, `localhost` is the container; use the `--connect-to` form from
  step 3 or run the check on the Docker host.
- **ACME challenge blocked.** Port 80 must reach the ingress from the internet
  for issuance and renewal. Open it in the security group or network security
  group (a cloud console change the user makes), then delete the stuck
  `certificaterequest` after confirmation so cert-manager retries:
  `kubectl delete certificaterequest <name> -n <ns>`.
- **Ingress controller pods unhealthy.** Treat as family B for that pod. A
  rollout restart of the controller, after confirmation, is acceptable only when
  its pods are Running but the load balancer stays unhealthy:
  `kubectl -n ingress-nginx rollout restart deploy/ingress-nginx-controller`.
- **502, 503, or 504 with a healthy ingress and a valid certificate.** The
  backend is down or slow: go to family B (pods) and then family E (runtime).
  Do not touch the ingress.

Never edit Ingress, Gateway, or Service objects by hand: Terraform and the chart
own them and the next apply reverts the change.

## Needs a GoodData support ticket

- DNS resolves, the certificate is valid, the ingress path is healthy, every pod
  is Running, and the organization still answers 5xx from the API gateway after
  family E came back clean.
- The organization controller reports the Organization as ready but the
  hostname returns 404 from GoodData.CN itself (not from the ingress).

Do not retry DNS or certificate steps at this point; they are proven.

## What to include

The `curl -kvI` output, `kubectl get ingress -A -o wide` (or the Gateway
listing), `kubectl describe certificate` for the affected hostname, the
`ingress_controller` and `tls_mode` values, and the controller log tail.

## Deeper investigation (observability on)

Nothing beyond the kubectl path; ingress health is fully visible without
metrics. Dashboard section 2 (API request rate by upstream) confirms whether
requests reach the API gateway at all once the path is healthy.

## See also

- The "Verify" section of the matching `install-gdcn` cloud reference.
- Family B for controller pods, family E for backend errors.
