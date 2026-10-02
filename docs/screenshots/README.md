# 記事用スクリーンショット

2026-10-02の実AWS検証から採取。記事では「実AWSコンソール」と「保存済みCLI出力の表示」を区別する。
画像の元になるテキストは [../evidence/](../evidence/)、結果・制約は [検証記録](../verification.md) を参照。

| 画像 | 種類 | 記事用キャプション案 |
|---|---|---|
| [01-eks-active.jpg](01-eks-active.jpg) | AWSコンソール | 新規EKSのコントロールプレーンがActive。Kubernetes 1.36、Standard supportで検証した。 |
| [02-ready.jpg](02-ready.jpg) | 実CLI出力の表示 | 6種類のAWSリソースとアプリがReady。HTTPで保存・取得したバイナリのSHA256が一致した。 |
| [03-failure.jpg](03-failure.jpg) | 実CLI出力の表示 | S3 PutObjectをDenyすると、MRのReady=Trueを保ったまま、アプリのReady=FalseとS3の403を観測した。 |
| [04-recovered.jpg](04-recovered.jpg) | 実CLI出力の表示 | 専用Denyを除去すると、Pod再作成コマンドなしでReady=Trueに戻った。 |
| [05-retained.jpg](05-retained.jpg) | 実CLI出力の表示 | StorageApp・Deployment・MRが消えても、元データ・S3公開ブロック・AES256暗号化は残った。 |
| [06-reconnected.jpg](06-reconnected.jpg) | 実CLI出力の表示 | 同じstorageIdで再作成し、新Podから元ファイルをHTTP GET。保存時・削除後・再接続後のSHA256が一致した。 |
| [07-s3-object-retained.jpg](07-s3-object-retained.jpg) | AWSコンソール | アプリ削除後もuploads/probe.binがS3に残る。39バイト、更新時刻は最初のHTTP PUT時のまま。 |
| [08-eks-deleted.jpg](08-eks-deleted.jpg) | AWSコンソール | 後片付け後の東京リージョンのEKS一覧は0件。S3の元データは引き続き取得できた。 |

CLI画面は `scripts/capture-evidence.sh` の記録を `scripts/render-evidence.py` でHTMLにし、ブラウザで撮影した。
画面に採取時刻と出典を表示し、実際のAWSコンソールのように見せていない。
01・07・08は実AWSコンソールを撮影時に切り出し、アカウント名・IDの表示領域を除いた。
CLIテキスト内のアカウントIDは採取時に `ACCOUNT_ID` へ置換している。状態・エラー・ハッシュ値は実出力。

スクリーンショットは特定時点の記録であり、現在のAWSリソースの存在を示すものではない。
EKSは検証後に削除済み。最終的な削除確認は [検証記録](../verification.md#後片付け) を参照。
