# Cost estimate

This is a planning range, not a quote. It assumes `ap-south-1`, on-demand Linux, low demo traffic, three ALB AZ subnets, no NAT egress beyond image pulls and test traffic, and teardown after the lesson. Verify with the [AWS Pricing Calculator](https://calculator.aws/) using the account's actual region and workload. Cost varies by region, discounts, transfer, CloudWatch ingestion, current pricing, and runtime.

The baseline is one `t3a.xlarge` (4 vCPU, 16 GiB) and Karpenter can launch up to four `t3a.large` nodes (2 vCPU, 8 GiB each). T3a is a burstable class; the advertised CPU count is not guaranteed at full sustained performance. AWS documents a 40% per-vCPU baseline for `t3a.xlarge` and 30% for `t3a.large`, with Unlimited-mode surplus credits chargeable above the rolling baseline. AWS EKS guidance recommends avoiding T-series for workloads that require consistent CPU; this demo uses them to lower the cost of short, mostly idle learning sessions. [T3a specs and CPU credit behavior](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-credits-baseline-concepts.html), [EKS data-plane guidance](https://docs.aws.amazon.com/eks/latest/best-practices/scale-data-plane.html).

The five-hour estimate is about **$2–$5 with only the baseline node**, or **$4–$8 if all four Karpenter worker nodes run for most of the session**. This is within the stated $8–$20 session target in the modeled case, but not guaranteed. Allow more budget if provisioning/debugging extends the session, images are repeatedly pulled, NAT egress is high, or T3a CPU-credit charges accrue. The month-long idle estimate is approximately **$9–$14/day with the baseline only** and **$14–$24/day with all four worker nodes continuously running**. Recheck `ap-south-1` prices in the AWS Pricing Calculator before applying.

| Cost item | Estimate basis | 5 hours, baseline | 5 hours, peak |
|---|---|---:|---:|
| EKS control plane | Standard support currently $0.10/cluster-hour | $0.50 | $0.50 |
| Baseline EC2 | One `t3a.xlarge` (4 vCPU, 16 GiB); planning estimate about $0.10/hour in Mumbai | $0.50 | $0.50 |
| Karpenter EC2 | 0–4 `t3a.large` (2 vCPU, 8 GiB each); about $0.05/hour each; 8-vCPU hard cap | $0 | ~$1.00 |
| EBS root volumes | 30 GiB gp3 per node; retained while instance exists | $0.05 | ~$0.11 |
| NAT Gateway | Example rate $0.045/hour plus $0.045/GB processed; cross-AZ egress may add transfer | $0.23 + data | $0.23 + data |
| ALB | Example $0.0225/hour plus LCU-hour charges | $0.15–$0.25 | $0.15–$0.25 |
| Public IPv4 | NAT EIP plus roughly one ALB address per enabled AZ at $0.005/address-hour; ALB can scale addresses | ~$0.10 | ~$0.10 |
| WAF | One ACL, one managed rule group, one rate rule; monthly fees prorated plus requests | ~$0.05 + requests | ~$0.05 + requests |
| CloudWatch logs/metrics | EKS control-plane logs, 7-day retention, low demo volume | $0.05–$0.50 | $0.05–$0.50 |
| X-Ray | Low trace volume from the short workflow | <$0.05 | <$0.05 |
| S3, DynamoDB, SQS, ECR | Low request count and short artifact retention; ECR image storage varies with image sizes | <$0.20 | <$0.20 |
| Route 53 | Existing hosted zone; no new zone; ALB alias queries are free | $0 incremental | $0 incremental |
| ACM | Non-exportable public ACM cert attached to ALB | $0 certificate | $0 certificate |

The modeled totals round up to the ranges above to allow for data, CPU-credit charges, and price variation. The baseline floor from EKS, node, NAT, ALB, IPv4, and WAF is roughly $0.30/hour before storage, data, and metrics. At the 8-vCPU Karpenter ceiling, worker instances add about $0.20/hour before CPU-credit charges. A Karpenter node can remain billable until it is empty for five minutes, drains, and terminates.

### Fixed hourly charges versus use

- **Continue while idle:** EKS, baseline EC2/EBS, NAT Gateway/EIP, ALB/LCUs, public IPv4, WAF, and possibly CloudWatch ingestion. Stopping bot Pods does not stop them.
- **Scale with session use:** Karpenter EC2/EBS, NAT data processing, internet transfer, ALB LCUs, WAF requests, X-Ray traces, S3 requests/storage, DynamoDB requests, and queue use.
- **T3a CPU credits:** `t3a.large` has a 30% per-vCPU baseline and `t3a.xlarge` a 40% baseline. They launch in Unlimited mode by default. Sustained CPU above the baseline can create surplus-credit charges; monitor `CPUCreditBalance` and `CPUSurplusCreditsCharged` in CloudWatch. AWS EKS guidance recommends avoiding burstable T nodes for workloads needing consistent CPU, so this choice is for a short, mostly idle learning demo. See [EC2 burstable credit behavior](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-credits-baseline-concepts.html) and [EKS data-plane guidance](https://docs.aws.amazon.com/eks/latest/best-practices/scale-data-plane.html).
- **Regional or bill-period details:** EKS standard support is $0.10 per cluster-hour; extended support is $0.60 per cluster-hour. AWS documents $0.045/hour and $0.045/GB as NAT examples; actual Mumbai prices can differ. Public IPv4 is listed at $0.005/address-hour. ALB has an hourly load-balancer charge and LCU charges; pricing is regional. The WAF Web ACL/rules are billed monthly and prorated by hour, and request charges are additional. See [EKS pricing](https://aws.amazon.com/eks/pricing/), [VPC pricing](https://aws.amazon.com/vpc/pricing/), [ALB pricing](https://aws.amazon.com/elasticloadbalancing/pricing/), and [WAF pricing](https://aws.amazon.com/waf/pricing/).
- The existing Route 53 hosted zone can still incur its normal monthly zone fee; the project does not create or delete it. Route 53 lists $0.50/month for the first 25 hosted zones and no charge for alias queries to ELB. See [Route 53 pricing](https://aws.amazon.com/route53/pricing/).
- Public ACM certificates used only with integrated services such as Elastic Load Balancing are no-cost; associated ALB/networking remain billable. See [ACM pricing](https://aws.amazon.com/certificate-manager/pricing/).

### Spending controls and choices

- `NodePool.spec.limits.cpu: 8` caps Karpenter capacity to four `t3a.large` nodes. Requests and this limit do not cap baseline nodes or AWS services.
- The monthly `aws_budgets_budget` defaults to $20 and filters by `Project=meeting-bot-platform`. Set `budget_alert_email` for actual-cost email notices at 80% and 100%. AWS cost allocation tags must be activated before tag-filtered costs appear. Budget delivery can lag and a budget is not a hard spend cap.
- One NAT Gateway saves two additional NAT hourly charges but makes private-subnet outbound access depend on one AZ and can incur cross-AZ transfer. S3/DynamoDB use gateway endpoints.
- One baseline node and one ALB are retained for a working API/control plane. To reduce cost further, destroy the environment between lessons; shutting down only workloads leaves the main fixed charges.
- The artifact bucket expires objects after seven days. The teardown's Terraform destroy empties and deletes this project bucket, so copy any artifact you need first.
