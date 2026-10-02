# KRO + Crossplane + EKSでS3付きアプリをセルフサービス化する――「作成できた」と「使える」を検証した

> 編集用の下書きです。本文中の「追記メモ」は、感想や自社の事情を加えるための場所です。公開時に削除してください。

自社のIDP（Internal Developer Platform）を考えるために、KROとCrossplaneを組み合わせて、小さなセルフサービスAPIを作りました。

開発者が `StorageApp` というKubernetesのカスタムリソースを1つ作ると、アプリのDeploymentに加えて、専用のS3バケット、IAMロール、EKS Pod Identity Associationが用意される構成です。

今回確かめたかったのは、作成後の振る舞いです。AWSのリソースがReadyになっても、アプリから使えるとは限りません。また、アプリを削除するとき、データまで同じ寿命にしてよいのかも決める必要があります。

そこで、新規EKS上で次の流れを実行しました。

1. アプリ経由でS3へファイルを保存し、取得したバイト列が一致することを確認する。
2. 権限を一時的に不足させ、StorageAppのReadyが変わることと、復旧することを確認する。
3. アプリを削除してS3を残し、同じIDで作り直したアプリから元のファイルを取得する。

結果として、この3つを確認できました。一方、実AWSに載せて初めて分かったIAM権限とPod Identityの注意点もありました。この記事では、成功した構成と、そこまでに直した部分を紹介します。

実装は [kro-crossplane-eks-idp-lab](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab)、詳しい記録は [AWS検証記録](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab/blob/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/verification.md) に置いています。検証日は **2026年10月2日**、リージョンは東京です。

> **追記メモ①：** 自社で今、アプリ用ストレージやIAMの依頼をどう受けているか。どの待ち時間・手作業を減らしたくてIDPを調べているかを、公開できる範囲で2〜3文足す。

## 作ったものと、3つの技術の役割

この記事でいうセルフサービスは、まずKubernetes API経由のものです。ポータル画面は作らず、開発者が1つのYAMLを適用するところを入口にしました。

![構成図：開発者のStorageAppをKROがKubernetesリソースとMRへ展開し、CrossplaneのAWS ProviderがAWSリソースを管理する](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/diagrams/01-architecture.png)

*図1：リソースを作る経路と、アプリがS3を読み書きする経路を分けた構成図。Provider自身の認証もPod Identityを使う。図は責務の概略で、RGDの依存グラフをそのまま描いたものではない。*

| 部分 | 今回持たせた責務 |
|---|---|
| KRO | 独自APIのスキーマ、リソース間の参照・依存関係、Ready条件 |
| CrossplaneとAWS Provider | Managed Resource（MR）を通じたAWS APIの操作と継続的な同期 |
| EKS | コントローラーとアプリの実行基盤、Pod Identityによる認証 |
| eksctl / CloudFormation | EKS本体、Provider用IAM、権限境界などの事前準備 |

KROには `ResourceGraphDefinition`（RGD）を登録します。RGDには、公開するAPIの形と、そこから作るリソースのテンプレートを書きます。今回はKROがAWS Providerのnamespaced MRを直接生成し、**CrossplaneのCompositionは使っていません**。

Crossplane v2では、CompositionからDeploymentやServiceを含むKubernetesリソースも合成できます。そのため、同様のAPIをCrossplane側にまとめる構成も比較対象になります。今回は「KROにAPIと依存関係を持たせ、AWS操作をProviderに任せる」という分担を試しました。[Crossplane v2の変更点](https://docs.crossplane.io/v2.4/whats-new/) に、この合成機能とnamespaced MRの説明があります。

EKS本体とProviderの認証は先に用意します。管理対象のEKSができるまで、そのEKS上のコントローラーを動かせないためです。今回のStorageAppがセルフサービス化する範囲は、用意済みのEKS上に載せるアプリと、そのアプリ用AWSリソースです。

## バージョンはAPIの形とセットで確認する

主要なバージョンは固定し、AWSが決めるパッチやアドオンの実際の値も記録しました。

| コンポーネント | 今回使ったバージョン |
|---|---|
| KRO | 0.9.4 |
| Crossplane | 2.4.2 |
| AWS Provider（family / S3 / IAM / EKS） | 2.8.1 |
| EKS Kubernetes | v1.36.4-eks-cfb47f5（指定は1.36） |
| EKS platform | eks.14 |
| EKS Pod Identity Agent | v1.3.10-eksbuild.3 |
| eksctl / Helm | 0.230.0 / 3.22.0 |
| Go | 1.27.1 |

特に、この記事のMRは `s3.aws.m.upbound.io/v1beta1` のように、APIグループに **`.m.` が入るnamespaced版**です。今回固定したCRDでは `providerConfigRef` に `name` と `kind` を指定し、削除時の保持は `managementPolicies` で表します。過去のサンプルを使うときは、そのまま混ぜず、利用するProvider版のCRDと照合します。

Helmチャート、検証用CRD、コンテナイメージもハッシュまたはdigestを保存しました。一方、EKSアドオンは初回作成時に対応版を解決して保存する方式です。「次に実行してもAWS側まで完全に同じ版になる」という固定ではありません。全アドオンとイメージの実測値は [versions.json](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab/blob/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/evidence/versions.json) にあります。

![実AWSコンソール：新規EKSがActive、Kubernetes 1.36](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/screenshots/01-eks-active.jpg)

*スクショ1：実AWSコンソール。Kubernetes 1.36の新規EKSがActiveになった状態。アカウント情報が出る領域は撮影時に除いている。*

検証環境は `m7i.xlarge` のワーカーノード1台です。NAT Gatewayと外部Load Balancerは作らず、アプリにはClusterIPとlocalhostのport-forwardで接続しました。これは短時間の検証用の構成です。

## 開発者に渡すのはStorageAppだけ

開発者側の入力は、ストレージのID、イメージ、レプリカ数の3つにしました。

```yaml
apiVersion: platform.example.com/v1alpha1
kind: StorageApp
metadata:
  name: demo
  namespace: idp-lab
spec:
  storageId: demo
  image: ACCOUNT.dkr.ecr.ap-northeast-1.amazonaws.com/idplab-LAB/storage-api@sha256:DIGEST
  replicas: 1
```

`image` は説明用のプレースホルダーです。実行スクリプトは、ビルドしてECRにpushしたイメージのdigestを使います。

リージョンやIAM権限、バケットの公開設定はプラットフォーム側で決めます。`storageId` は作成後に変更できず、レプリカ数は1〜3に制限しました。実EKSでも、`storageId` の変更と `replicas: 4` はAPIサーバーに拒否され、開発者の権限で1→2→1のスケールができることを確認しています。

開発者のServiceAccountにはStorageAppの操作を許可し、IAMのMR作成やプラットフォーム設定のConfigMap変更は許可しません。この拒否も実EKSのimpersonationで確認しました。

ただし、今回の共有Namespace内では他のStorageAppも編集でき、任意のアプリイメージを指定できます。また、同じ `storageId` を同時に使うことを防ぐ所有権・一意性の制御は実装していません。ここは後述する自社IDPへの宿題です。

### RGDで依存関係とReadyを定義する

実装したMRは次の6種類です。

| MR | AWS側で管理するもの |
|---|---|
| Bucket | S3バケット |
| BucketPublicAccessBlock | 公開アクセスのブロック |
| BucketServerSideEncryptionConfiguration | デフォルト暗号化 |
| Role | アプリ用IAMロール |
| RolePolicy | アプリのS3アクセス権限 |
| PodIdentityAssociation | EKSのServiceAccountとIAMロールの関連付け |

KROのテンプレートでは、他のリソースの値をCEL式で参照します。例えばAssociationがRoleのARNを参照し、DeploymentがAssociationのIDを参照します。アプリ用ポリシーの準備も待つよう、AssociationのannotationにRolePolicyへの参照を置きました。

MRについては `Ready=True` と `Synced=True` の両方を待ちます。Deploymentについては、更新対象の世代が観測され、更新済み・利用可能レプリカがともに要求数と一致することを条件にしました。

```yaml
# platform/storage-app.yaml の抜粋
- id: deployment
  readyWhen:
    - ${deployment.status.observedGeneration == deployment.metadata.generation}
    - ${deployment.status.?updatedReplicas.orValue(0) == deployment.spec.replicas}
    - ${deployment.status.?availableReplicas.orValue(0) == deployment.spec.replicas}
```

ここで、Deploymentの利用可能性を何で判断するかが、次のreadiness probeにつながります。

## 「S3がある」から「アプリで読み書きできる」まで確認する

検証用アプリは、Goで作った小さなHTTP APIです。

| API | 振る舞い |
|---|---|
| `GET /healthz` | プロセスの生存確認。AWSアクセスはしない |
| `GET /readyz` | 同じバケットの一時オブジェクトをPut / Get / Deleteし、内容を照合する |
| `PUT /objects/{key}` | 最大1 MiBをS3の `uploads/` 配下に保存する |
| `GET /objects/{key}` | 保存したファイルを取得する。存在しなければ404 |

生存確認とreadinessを分け、S3の問題だけでプロセスを再起動する構成にはしていません。readinessは10秒周期を設定し、専用の `_health/` キーを使います。アプリの削除権限も、このヘルスチェック用プレフィックスだけに限定しました。

通常の動作確認では、HTTPでバイナリをPUTし、GETしたデータと元ファイルのSHA256を比較しました。バケットの存在やHTTPのステータスコードだけでなく、保存・取得したバイト列まで一致しました。

![実CLI出力：StorageAppと6種類のMRがReady、HTTPで往復したファイルのSHA256が一致](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/screenshots/02-ready.jpg)

*スクショ2：保存した実CLI出力をHTMLにして撮影したもの。AWSコンソールではない。StorageApp、Deployment、6種類のMRの状態と、バイナリ往復の結果をまとめている。以降のCLI画面も同じ方式で、アカウントIDだけを置換している。*

Pod Identityで取得する短期認証情報を使い、アプリにもProviderにも長期アクセスキーを持たせていません。アプリではIMDSからの認証情報取得も無効にしています。

## 権限を壊すと、どのReadyが変わるのか

次に、アプリ用IAMロールへ専用のインラインポリシーを追加し、`_health/*` に対する `s3:PutObject` を一時的にDenyしました。

このDenyは、Crossplaneが管理するRolePolicyとは別のポリシーです。バケットやAssociationを壊さず、アプリのreadinessだけを失敗させる実験にしています。

![障害伝播の図：MRはReadyのまま、S3の権限不足がreadiness、Deployment、StorageAppへ伝わる](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/diagrams/02-readiness.png)

*図2：今回観測した状態の伝播。S3 APIの403をアプリが検知し、Pod・Deploymentを経由してStorageAppのReady=Falseにつながる。即時に全層が変わるわけではない。*

実際の結果は次のとおりでした。

| 観測したもの | Denyの前 | Denyの反映後 |
|---|---|---|
| 6種類のMRのReady / Synced | すべてTrue | **すべてTrueのまま** |
| アプリのS3ヘルスチェック | 成功 | PutObjectが403 / AccessDenied |
| Deployment | 1/1 | 0/1 |
| StorageApp | Ready=True | Ready=False、STATE=IN_PROGRESS |

![実CLI出力：MRはReady=Trueのまま、StorageAppはReady=False、S3 PutObjectは403](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/screenshots/03-failure.jpg)

*スクショ3：この記事の中心となる観測。MRの状態と、アプリがチェックした実アクセスの結果は一致するとは限らない。*

MRのReadyとSyncedは、そのリソースについてProviderが観測した状態です。今回、そこからアプリ用認証情報によるS3操作の成功までは分かりませんでした。Deploymentを経由して実アクセスのreadinessをStorageAppへつなぐことで、開発者が見るAPIにも異常を返せました。

ただし、今回Denyしたのは **`_health/*` だけ**です。この実験は「`uploads/*` の操作も403になった」という証拠ではありません。同じバケット・認証情報でもプレフィックスごとの権限は異なるため、何をもって「使える」とするかは、probeと実際の利用経路を合わせて設計する必要があります。通常系の `uploads/*` は、前節のHTTP Put/Getで別に確認しています。

専用Denyを取り除くと、Podを再作成するコマンドを実行せずに、StorageAppはReady=Trueへ戻りました。

![実CLI出力：Denyを除去した後、Deployment 1/1とStorageApp Ready=Trueへ復旧](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/screenshots/04-recovered.jpg)

*スクショ4：権限の復旧後。実験スクリプトはEXIT時にも専用Denyを除去する。*

readinessにはS3リクエストが発生します。また、依存先の障害で全PodがNotReadyになる設計が、そのサービスに合うかは別途考える必要があります。このラボでは、S3が使えない状態を開発者APIへ返すことを優先しました。

> **追記メモ②：** 自社IDPのReadyにどこまで含めたいか。外部依存の確認を常時probeに入れるか、作成時の疎通試験や別の監視に分けるかについて、今回の感想を足す。

## アプリを消してもデータは残し、再作成したアプリから読む

StorageAppの削除では、アプリとIAM、Pod Identity Associationを片付けます。一方、S3バケットとデータ、公開ブロック、暗号化設定は残す方針にしました。

S3関連の3種類のMRには、次の設定を使っています。

```yaml
spec:
  managementPolicies: [Observe, Create, Update, LateInitialize]
  providerConfigRef:
    name: aws
    kind: ProviderConfig
```

ここでは `Delete` を含めていません。Kubernetes上のMRが削除されても、対応するAWS上のリソースや設定を削除しないための指定です。Bucketだけ保持して保護設定が消えることを避けるため、公開ブロックと暗号化のMRも同じ方針にしています。

![保持と再接続の図：アプリ削除後にS3を残し、同じstorageIdで再作成したPodから元のデータを読む](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/diagrams/03-retention.png)

*図3：同一アカウント・同一ラボ設定で実施した保持と再接続。S3のMRは一度消え、再作成時に同じ外部バケット名へ接続する。*

削除後に確認したのは、次の状態です。

- StorageApp、Deployment、6種類のMRがKubernetes上から消えた。
- S3には元のファイルが残り、SHA256が一致した。
- S3の公開ブロック4項目がすべて有効で、デフォルト暗号化はAES256だった。

![実CLI出力：アプリとMRの削除後も、S3のデータと保護設定が残る](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/screenshots/05-retained.jpg)

*スクショ5：削除完了後、再作成前の記録。空のリソース一覧と、S3側の保護設定・データ照合を一緒に残した。*

続いて同じ `storageId: demo` でStorageAppを作り直しました。このラボでは、ラボ固有のprefixと `storageId` からバケット名を決めます。同じ設定なら、保持したバケットと同じ外部名になります。

ここで元ファイルは再アップロードせず、**新しいPodのHTTP APIからGET**しました。元ファイル、アプリ削除後にS3から取得したファイル、再接続したアプリから取得したファイルのSHA256が一致しました。新PodのrestartCountは0です。

![実CLI出力：再作成したアプリから元のファイルを取得し、3つのSHA256が一致](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/screenshots/06-reconnected.jpg)

*スクショ6：再接続後。AWS CLIで残存を確認するだけでなく、新Podの認証情報とアプリ経由の読み取りも確認した。*

これは、同一ラボ設定での再接続試験です。任意の既存バケットのimportや、管理クラスタを失った後の別クラスタへの復旧を確認したものではありません。また、削除を防いで残すことと、誤更新や障害に備えるバックアップは別に設計する必要があります。

## 実AWSで見つかった3つの注意点

事前のkind検証では、実KROと実Provider CRDを使い、型、依存待ち、入力制約、更新、削除を確認しました。ただし、AWS側のstatusは模擬しています。AWSに対する権限評価や反映タイミングは、実EKSで確認する必要がありました。

### 1. IAM Roleの初回ObserveがGetRoleで拒否された

IAM Providerの権限をworkloadsパスのロールに限定したところ、まだ存在しないロールを調べる最初のGetRoleで403になりました。

今回のProviderでは、初回Observeのために、ラボ名のprefixで絞ったrootパスのロールARNにも `iam:GetRole` を追加することで、作成へ進みました。IAMのGetRole APIはRoleNameを入力とするAPIです。[GetRoleのAPI仕様](https://docs.aws.amazon.com/IAM/latest/APIReference/API_GetRole.html) と [実際のエラー](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab/blob/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/evidence/iam-observe-error.txt) を併せて確認しました。

追加したのは、この範囲の読み取りだけです。ロール作成・更新・削除はworkloadsパスに限定し、作成時には指定のpermissions boundaryを必須にしています。ただし、同じラボ名のProviderロールのメタデータもGetRoleで読める範囲に入る点は、権限設計上の変更として記録しました。

### 2. Association作成にも対象ロールのGetRoleが必要だった

EKS ProviderにPassRoleを許可していても、Association作成時に次のエラーになりました。

```text
Caller does not have permission to perform iam:GetRole
```

対象workloadsパスへの `iam:GetRole` を別Statementで追加して解消しました。PassRoleに付けた `iam:PassedToService=pods.eks.amazonaws.com` の条件を、GetRoleにもまとめて付けないようにしています。

AWSの [Pod Identityを管理する実装例](https://aws.amazon.com/blogs/containers/how-to-manage-eks-pod-identities-at-scale-using-argo-cd-and-aws-ack/) にも、GetRoleとPassRoleを分けたポリシー例があります。こちらの [エラー記録](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab/blob/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/evidence/association-error.txt) も残しました。

### 3. AssociationのReady直後に作ったPodで、認証設定の注入が間に合わなかった

AssociationがReadyになった直後のPodでは、Pod Identity用の `AWS_CONTAINER_*` 環境変数と投影トークンが注入されておらず、認証情報を取得できませんでした。同じPodテンプレートでPodを作り直すと注入され、Readyになりました。

AWSはAssociation作成APIについて、変更の反映が結果整合的であることを説明しています。今回の観測はその説明と整合しますが、内部キャッシュの原因まで特定したわけではありません。[CreatePodIdentityAssociationの仕様](https://docs.aws.amazon.com/eks/latest/APIReference/API_CreatePodIdentityAssociation.html)

最終実装では、このIPv4ラボのDeploymentに、AWSが公開するPod Identityの環境変数と専用トークン投影を明示しました。

```yaml
# アプリコンテナのenvの抜粋
- name: AWS_CONTAINER_CREDENTIALS_FULL_URI
  value: http://169.254.170.23/v1/credentials
- name: AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE
  value: /var/run/secrets/pods.eks.amazonaws.com/serviceaccount/eks-pod-identity-token
```

トークンは `audience: pods.eks.amazonaws.com`、有効期間86400秒のServiceAccount tokenを専用volumeに投影し、読み取り専用でmountします。Kubernetes API用トークンの自動mountは無効のままです。形式は [AWSのPod Identity動作説明](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-how-it-works.html) に合わせました。

認証情報の取得に必要な設定を最初からPodに用意し、Associationが有効になるまでSDKとreadinessの再試行で待てるようにしています。これで結果整合性がなくなるわけではありません。修正後の削除・再作成試験では、手動のPod再作成なしで元データを取得できました。

この対応はIPv4構成向けで、Pod Identity Agentの公開仕様に依存します。採用する構成やAgentの版を変えるときは、テンプレートの見直しと再作成試験もセットにします。

## 試す場合の入口と後片付け

リポジトリには、一連の操作をMakeターゲットとして用意しました。AWS CLIのSSOプロファイル、期待するアカウントID、リージョン、新しい `LAB_ID`、管理者のIPv4 /32を `.env` に設定してから実行します。必要なツールと準備は [README](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab/blob/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/README.md#前提と準備) を参照してください。

この記事のコード・証跡リンクは検証済み実装を含むコミットに固定しています。取得して試す場合も、同じ版から始められます。

```bash
git clone https://github.com/suzuki0430/kro-crossplane-eks-idp-lab.git
cd kro-crossplane-eks-idp-lab
git checkout 49a3bae7e3c6198f3a15caefa5adbd2f41d5b658
# 続いてREADMEの「前提と準備」を実施する
```

```bash
# ローカル検証
make check test
make graph

# ここからAWSリソースを作成する
make cluster
make bootstrap
make platform
make image
make demo

# 作成・障害・保持と再接続を検証する
make verify
make verify-iam
make failure
make retention

# 最後にEKS等を削除する。S3は保持する
make cleanup
```

クラスタの作成から片付けまで、EKS、EC2、EBS、public IPv4などの料金が発生します。今回のEKS作成は約14分33秒、cleanupは約12分52秒でした。いずれも1回の実行結果です。初回アプリ作成には調査・修正も含まれるため、通常のプロビジョニング時間としては紹介しません。

cleanupは、先にStorageAppとMRの削除を完了させてから、Provider用の認証基盤とEKSを削除します。MRのfinalizer処理中に、必要なコントローラーやIAMを先に消さない順序です。

検証後、EKS、VPC、ネットワークインターフェース、EBS、関連IAM、ECRの削除を確認しました。記録していたEC2もterminatedです。残したのはS3バケットと `uploads/probe.bin` の39バイトの検証データで、EKS削除後に取得したデータも元のSHA256と一致しました。

![実AWSコンソール：S3に残るuploads/probe.bin](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/screenshots/07-s3-object-retained.jpg)

*スクショ7：実S3コンソール。保持した39バイトの検証オブジェクト。*

![実AWSコンソール：後片付け後の東京リージョンのEKS一覧は0件](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/screenshots/08-eks-deleted.jpg)

*スクショ8：実EKSコンソール。検証後のクラスタ一覧は0件。関連リソースの削除は [AWS APIの最終確認](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab/blob/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/evidence/cleanup.txt) でも照合した。保持S3のストレージ・リクエスト等は引き続き料金の対象になる。*

## 自社IDPに持ち帰って考えたいこと

今回のラボでは、1つのAPIからAWSリソースとアプリを作り、実アクセスの異常を状態へ返し、データを残して再接続するところまで確認できました。

これを自社IDPの機能として提供するなら、次は次の契約を決めたいところです。

| 論点 | 決めること |
|---|---|
| APIとデータの所有権 | チーム別Namespace、storageIdの一意性、誰が保持データに再接続できるか |
| 実行できるもの | イメージの許可範囲、Pod Identityを使える主体、admissionによる制約 |
| Readyの意味 | どの操作を試すか、probe頻度、依存先障害の見せ方、利用者へのエラーメッセージ |
| データの寿命 | 保持期限、完全削除の手順、バックアップ、管理クラスタ喪失後の復旧 |
| 変更の進め方 | RGD・Provider・アプリの互換性試験、段階的更新、ロールバック |

IAMシミュレーターでは、境界なしのロール作成や境界除去などの拒否も確認しました。ただし、これはポリシー評価であり、別Namespaceや別ServiceAccountからの実アクセス拒否をすべて試したものではありません。今回の共有Namespaceのラボで、敵対的な利用者間の分離まで証明したとは扱いません。確認範囲は [認証・権限のレビュー](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab/blob/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/security-review.md) に分けて記録しています。

> **追記メモ③：** KROとCrossplaneを併用して分かりやすかった点・複雑になった点、自社なら最初にどの契約を固めたいかを書く。Crossplane単独のComposition構成と比べてみたい点も、ここに足せる。

## 実装・検証資料

- [リポジトリと実行手順](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab/blob/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/README.md)
- [StorageAppのRGD](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab/blob/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/platform/storage-app.yaml)
- [実AWSの検証結果・バージョン・所要時間](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab/blob/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/verification.md)
- [スクショの出典とキャプション](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab/blob/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/screenshots/README.md)
- [IAM・認証設計と試験範囲](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab/blob/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/security-review.md)
