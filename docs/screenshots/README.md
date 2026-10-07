# Article screenshots

All visible captions and UI labels are in English, for reuse on Qiita and dev.to.
The screenshots distinguish the actual AWS console from browser views of saved CLI output.

| Image | Source | Validation / capture date (JST) |
|---|---|---|
| [01-eks-active.jpg](01-eks-active.jpg) | Actual AWS console: the new **Composition-only** EKS `idplab-cp1004a` is Active, Kubernetes 1.36 | 2026-10-04 |
| [02-ready.jpg](02-ready.jpg) | [KRO run: ready](../evidence/ready.txt). Six MRs and the app are ready; the binary HTTP round trip matches | Validated Oct 2; English view captured Oct 4 |
| [03-failure.jpg](03-failure.jpg) | [KRO run: failure](../evidence/failure.txt). Denying health-probe PutObject leaves MRs ready while app readiness fails | Validated Oct 2; English view captured Oct 4 |
| [04-recovered.jpg](04-recovered.jpg) | [KRO run: recovered](../evidence/recovered.txt). Removing the test Deny restores readiness | Validated Oct 2; English view captured Oct 4 |
| [05-retained.jpg](05-retained.jpg) | [KRO run: retained](../evidence/retained.txt). Original data, public-access block and encryption survive app deletion | Validated Oct 2; English view captured Oct 4 |
| [06-reconnected.jpg](06-reconnected.jpg) | [KRO run: reconnected](../evidence/reconnected.txt). A newly created Pod reads the original file without another upload | Validated Oct 2; English view captured Oct 4 |
| [07-s3-object-retained.jpg](07-s3-object-retained.jpg) | Actual AWS console: the **original KRO-run** `uploads/probe.bin`, 39 bytes, still has its Oct 2 modification time | Captured Oct 4 |
| [08-eks-deleted.jpg](08-eks-deleted.jpg) | Actual AWS console: Tokyo has zero EKS clusters after both labs have been removed | Captured Oct 4 |
| [09-composition-ready.jpg](09-composition-ready.jpg) | [Composition run: ready](../evidence/composition/ready.txt). The same app behavior with no KRO installed | 2026-10-04 |
| [10-composition-reconnected.jpg](10-composition-reconnected.jpg) | [Composition run: reconnected](../evidence/composition/reconnected.txt). All three SHA256 values match | 2026-10-04 |

The CLI images use `scripts/render-evidence.py` to display captured text, followed by a browser screenshot.
The Oct 2 CLI records, timestamps, statuses, error text and hashes are unchanged; only the surrounding captions were translated.
The view filenames `composition-ready.txt` and `composition-reconnected.txt` are copies of the corresponding records in `docs/evidence/composition/`.

Console images 01, 07 and 08 were recaptured from the English AWS console, not translated over old pixels.
Crops exclude account/session information. Account IDs in CLI records are replaced with `ACCOUNT_ID` before publication.
Image 01 now shows the Oct 4 comparison cluster, not the deleted Oct 2 cluster.

These are historical observations, not live dashboards. See the [KRO validation](../verification.md),
[Composition comparison](../composition-comparison.md), and [Composition cleanup evidence](../evidence/composition/cleanup.txt).
