# AWS実環境の検証記録

2026-10-02、東京リージョンの新規EKSで実行。実装の修正を含む検証コミットは `77c4ab2`。
CLIの公開用記録は [evidence/](evidence/)、画像と説明は [screenshots/](screenshots/) に保存した。
アカウントIDを `ACCOUNT_ID` に置換し、kubeconfig・認証情報・未加工ログは公開していない。

## 結果

| 項目 | 実際の結果・証跡 |
|---|---|
| GitHub Actions | [マージ済み実装](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab/actions/runs/37004868883)、[修正後](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab/actions/runs/37007879958) とも成功 |
| Go単体テスト・race detector・go vet | 成功。HTTP 90.4%、S3アダプタ87.8%（server起動部分0%） |
| 静的検査・イメージビルド | CloudFormation lint、ShellCheck、Ruff、CRD SHA256、linux/amd64 buildが成功 |
| kind + 実KRO + Provider CRD | 型検査、依存待ち、エラー表示、入力制約、更新、finalizerを伴う削除のテストが成功。ここではAWS statusを模擬 |
| EKS・Provider | 新規EKSと全5アドオンがActive。KRO、Crossplane、family/S3/IAM/EKS Providerが起動 |
| 実AWSのリソース作成 | S3、公開ブロック、暗号化、IAM Role/RolePolicy、Pod Identity Associationの6種類がReady/Synced=True |
| HTTP Put/Get・404・RBAC | バイナリのSHA256一致、存在しないキーが404。開発者のStorageApp作成は許可、IAM MR作成・ConfigMap変更は拒否。[記録](evidence/ready.txt) |
| 一時的な権限不足 | `_health/*` のPutObjectをDeny。6種類のMRはReady=Trueのまま、Deploymentは0/1、StorageAppはReady=False。[記録](evidence/failure.txt) |
| 権限復旧 | 専用Denyポリシーの除去後、Podの再作成コマンドなしでReady=Trueへ復旧。[記録](evidence/recovered.txt) |
| アプリ削除 | StorageApp、Deployment、全6種類のMRが消えた後もS3のデータ・公開ブロック4項目・AES256暗号化が残存。[記録](evidence/retained.txt) |
| 同じstorageIdで再接続 | 新しいPodから元のファイルをHTTP GETし、SHA256一致。再アップロードなし。新PodのrestartCountは0。[記録](evidence/reconnected.txt) |
| API制約・更新 | storageId変更とreplicas=4をAPIサーバーが拒否。開発者権限で1→2→1の変更が完了。[記録](evidence/api-contract.txt) |
| IAMの権限境界 | IAMシミュレーターの7項目が期待どおり。境界なしのCreateRole、workloadsパス外のCreateRole、境界除去はimplicitDeny。[記録](evidence/iam-policy-simulation.txt) |

IAMシミュレーターはポリシー評価であり、別ServiceAccountからの実アクセス試験や悪意あるマルチテナントの隔離試験とは異なる。
今回の実AWS試験で確認した認証・権限の範囲は [security-review.md](security-review.md) を参照。

## 実際に使ったバージョン

| コンポーネント | バージョン |
|---|---|
| KRO / Crossplane / AWS Provider | 0.9.4 / 2.4.2 / 2.8.1 |
| EKS Kubernetes / platform | v1.36.4-eks-cfb47f5 / eks.14 |
| kubelet / AL2023 release | v1.36.4-eks-3b4a6ca / 1.36.4-20260930 |
| eksctl / Helm | 0.230.0 / 3.22.0 |
| Go | 1.27.1 |
| vpc-cni | v1.22.4-eksbuild.3 |
| kube-proxy | v1.36.0-eksbuild.25 |
| CoreDNS | v1.14.6-eksbuild.4 |
| EKS Pod Identity Agent | v1.3.10-eksbuild.3 |
| metrics-server | v0.9.0-eksbuild.11 |

JSONとアプリのイメージdigestは [versions.json](evidence/versions.json) を参照。
アドオンは初回実行時にAWSの対応版を解決して保存するため、実行日によって変わる。
ノード作成前のCoreDNSは一時的にDEGRADEDになり、ノード起動後にActiveへ収束した。

## 実AWSで見つかった3点と修正

### 1. IAM Roleの初回Observeに必要なGetRole

IAM Providerをworkloadsパスだけに制限すると、まだ存在しないロールを調べるGetRoleが403になった。
同じラボ名に限定したrootパスの `iam:GetRole` を追加すると、ObserveからCreateへ進んだ。
作成・更新・削除のworkloadsパス制限と、Create時のpermissions boundary必須条件は維持している。
追加範囲では同じラボのProviderロールのメタデータも読み取れる。
[エラー記録](evidence/iam-observe-error.txt)、[GetRoleのAPI仕様](https://docs.aws.amazon.com/IAM/latest/APIReference/API_GetRole.html)。

### 2. Association作成にも対象RoleのGetRoleが必要

EKS ProviderにPassRoleだけを付けた状態では、CreatePodIdentityAssociationが
`Caller does not have permission to perform iam:GetRole` で失敗した。
対象workloadsパスのGetRoleを別Statementで追加して解消。
PassRoleの `iam:PassedToService=pods.eks.amazonaws.com` 条件をGetRoleに付けない。
[エラー記録](evidence/association-error.txt)、[AWSのPod Identity管理例](https://aws.amazon.com/blogs/containers/how-to-manage-eks-pod-identities-at-scale-using-argo-cd-and-aws-ack/)。

### 3. AssociationのReadyとPodへの認証設定の注入は同時ではない

Association作成直後のPodには `AWS_CONTAINER_*` と投影トークンが注入されず、認証取得に失敗した。
同じPodテンプレートで再作成すると注入され、Readyになった。
AWSが説明するAssociationの結果整合性と整合する観測であり、内部キャッシュの挙動まで断定するものではない。

最終実装では、IPv4のラボ用DeploymentにAWSの公開仕様に沿った認証エンドポイント、
`pods.eks.amazonaws.com` audienceの投影トークン、読み取り専用mountを明示した。
これにより、Pod作成時の注入が間に合わなくても、SDKとreadinessの再試行で反映を待てる。
Kubernetes API用のトークン自動mountは引き続き無効。長期アクセスキーは使わない。
修正後の削除・再作成は手動Pod再作成なしで成功した。[Podの実観測値](evidence/pod-identity.json)。

[Associationの結果整合性](https://docs.aws.amazon.com/eks/latest/APIReference/API_CreatePodIdentityAssociation.html)、
[認証環境変数と投影トークンの仕様](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-how-it-works.html)。

## 時間の読み方

- EKS作成: 21:08:32〜21:23:05 JST、約14分33秒（eksctlログ）。
- 初回StorageAppスクリプト: 約506.85秒。IAM修正・原因調査・手動Pod再作成を含むため、通常の作成時間には使わない。
- 障害実験全体: 約73.77秒。AWS照合、Deny投入、観測、証跡保存、復旧までを含む。
- 保持・再接続実験全体: 約64.75秒。削除、S3照合、証跡保存、再作成、HTTP GETまでを含む。

いずれも1回のラボ実行結果であり、性能保証や平均値ではない。障害検出時間だけの厳密な計測は行っていない。

## 後片付け

2026-10-02 21:45:03〜21:57:56 JSTにcleanupを実行（約772.33秒）。
22:00 JST頃のAWS API照合で以下を確認した。[最終確認の出力](evidence/cleanup.txt)。

- Cluster / Nodegroup / BootstrapのCloudFormation stackはすべてDELETE_COMPLETE。
- 対象EKS、VPC、ネットワークインターフェース、EBS、関連IAM Role/ManagedPolicy、ECRは残存0。
- 記録しておいたEC2インスタンスはterminated。
- 保持S3は1バケット、オブジェクトは `uploads/probe.bin`（39バイト）だけ。
- EKS削除後の取得データも元のSHA256と一致。公開ブロック4項目とAES256暗号化を確認。

保持先名は `idplab-ACCOUNT_ID-kro1002a-demo`。実際の名前はGit除外の `.local/retained-buckets.json` に保存している。
S3のストレージ・リクエスト等の料金は保持中も対象となる。データの完全削除は行っていない。

## 過去の実行

2026-10-01は実装のみへ切り替える指示により、EKSコントロールプレーンの作成段階で中断し、
当日のEKS/VPC等を削除した。今回のAWS検証は別のLAB_IDで新規作成して実行した。
