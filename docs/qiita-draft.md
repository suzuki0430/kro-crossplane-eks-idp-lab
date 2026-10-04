# KRO + Crossplaneで、S3付きアプリをEKSに作ってみた。両方いる？ 消したらデータはどうなる？

> 編集用の下書きです。「追記メモ」は自分の感想を書き足す場所として残しています。公開するときに置き換えるか、削除してください。

きっかけは、自分も登壇したCNCJのイベントでした。

2026年9月25日の [Cloud Native Platform Engineering Japan Meetup #3 — Platform Engineering Kaigi 前夜祭スペシャル](https://ocgroups.dev/cncf/group/bqd97by/event/c3zf287) で、もう一つの発表がHENNGEのFurqan Habibiさんによる「Building elegant platform with KRO」でした。

KROは、もともとKubeConでセッションを聞いてから気になっていました。そこに今回の発表が重なり、「自分でも動かしてみよう」と思ったのが、今回の検証の出発点です。

自社のIDP（Internal Developer Platform）の勉強も兼ねて、KROとCrossplaneを組み合わせて試すことにしました。題材は、S3にファイルを保存する小さなアプリです。

やりたいことは、「このイメージでアプリを動かしたい」と伝えたら、Deploymentだけでなく、そのアプリ用のS3とIAMも一緒に用意してくれること。開発者が毎回バケットや権限を個別に設定しなくて済む形を目指します。

ただ、その前に整理したいことがあります。**KROとCrossplaneは、そもそも両方必要なのか。** 今回はここから説明して、実際のデプロイ、権限を壊したときの動き、アプリを消した後のデータまで見ていきます。

検証したのは2026年10月2日、東京リージョンの新規EKSです。[実装リポジトリ](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab) と [詳しい検証記録](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab/blob/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/verification.md) も公開しています。

> **追記メモ①：** HENNGEの発表やKubeConのセッションで特に気になった点、自社の状況と重なった点があれば、ここに1〜2文足す。

## まず、KROとCrossplaneは両方必要？

今回の目的なら、**Crossplane v2側にまとめても実現できます。KROの併用は必須ではありません。**

ここで「Crossplaneだけ」と呼ぶのは、AWS ProviderやCompositionで使うFunctionなどを組み込んだ、KROを使わない構成のことです。Crossplane本体をインストールするだけでAWSを操作できる、という意味ではありません。[Compositionの構成手順](https://docs.crossplane.io/v2.4/get-started/get-started-with-composition/)

EKSなどのKubernetesクラスタが用意されている前提で、整理するとこうなります。

| 構成 | 今回やりたいことができるか |
|---|---|
| KROだけ | DeploymentやServiceをまとめて作れる。ただし、KRO本体にはS3やIAMを操作する機能がないため、AWSを操作するコントローラーなどを別途足す必要がある |
| Crossplane v2 + AWS Provider | KROなしで実現できる。独自APIとCompositionを定義し、DeploymentとAWSのリソースをまとめて作る |
| KRO + Crossplane + AWS Provider | 今回の構成。独自APIとリソース同士のつなぎ込みをKROに、AWS操作をProviderに任せる |

KROが扱うのはKubernetesリソースです。例えばKROが `Bucket` というカスタムリソースを作っても、それだけでAWSにS3バケットができるわけではありません。その `Bucket` を見てAWS APIを呼ぶ担当が必要です。今回はCrossplaneのAWS Providerを使いました。KROの公式例では、この担当にACKを使っています。[KROの仕組みと例](https://kro.run/docs/overview/)

一方、Crossplane v2のCompositionは、AWSのリソースだけでなくDeploymentやServiceも扱えます。だから「KROがアプリ、Crossplaneがインフラ。両方そろって初めてできる」という説明だと、Crossplane側のできることを狭く捉えすぎてしまいます。[Crossplane v2の変更点](https://docs.crossplane.io/v2.4/whats-new/)

今回は、イベントをきっかけに気になった組み合わせを動かしてみることにしました。試した分担は、**KROで開発者向けのAPIを作り、AWS操作をCrossplaneのProviderに任せる形**です。機能上、両方が必要だったから選んだわけではありません。CrossplaneのCompositionは使っていません。

なお、この記事ではCrossplane単独版を実装して比較したわけではありません。単独版にするなら、KROの定義をCrossplaneのAPI定義・Compositionへ作り替え、Readyや削除時の動きも確認し直す必要があります。今の実装からKROだけをアンインストールすれば動く、という意味ではないです。

## 今回は、誰に何を任せたか

今回の入口は `StorageApp` というカスタムリソースです。開発者がこれを1つ作ると、KROが必要なKubernetesリソースを作ります。そのうちAWS向けのものを、ProviderがAWSへ反映します。

![構成図：開発者のStorageAppをKROがKubernetesリソースとMRへ展開し、CrossplaneのAWS ProviderがAWSリソースを管理する](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/1c6671021a87992443426ad157cd0dc894fe1807/docs/diagrams/01-architecture.png)

*図1：今回の分担。緑の矢印は、起動したアプリがS3を読み書きする経路です。*

| 担当 | 今回やってもらうこと |
|---|---|
| KRO | StorageAppのAPIを作り、必要なリソースと依存関係、Readyの条件を定義する |
| Crossplane + AWS Provider | S3、IAM、Pod Identity AssociationをAWS上に作り、状態を同期する |
| EKS | コントローラーとアプリを動かす。Pod IdentityでAWSの認証情報を渡す |
| eksctl / CloudFormation | EKS本体やProvider用のIAMなどを先に用意する |

EKS本体は、StorageAppを作る前に準備します。そのEKS上で動くKROやProviderを使って、起動前の自分自身を作ることはできないためです。今回セルフサービス化したのは、**用意済みのEKSに載せるアプリと、そのアプリ用のAWSリソース**です。

## アプリはどうデプロイした？

今回はターミナルからコマンドで実行しました。ポータル画面やGitOpsによるデプロイは作っていません。

EKSとコントローラーを準備した後、次のスクリプトを使います。

```bash
# アプリのイメージをビルドし、ECRへpushする
bash scripts/04-image.sh

# StorageAppを登録し、Readyになるまで待つ
bash scripts/05-demo.sh
```

Makefileには、同じ処理を `make image` と `make demo` でも呼べるようにしています。

アプリ側の入力は、ストレージのID、イメージ、レプリカ数の3つです。YAMLで書くとこの形になります。

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

ここでの `image` は説明用の値です。スクリプトは実際にECRへpushしたイメージのdigestを読み、この内容のJSONを生成します。最後にやっているのは、この `kubectl apply` です。

```bash
kubectl apply \
  --as=system:serviceaccount:idp-lab:developer-demo \
  -f .local/demo.json
```

`--as` は、開発者用ServiceAccountの権限で操作できるかを試すための指定です。今回の検証では、管理者の接続からこのServiceAccountとして操作しています。

コマンドが登録するのはStorageAppです。その後、KROがDeploymentなどを作り、Kubernetesの標準コントローラーがPodを起動します。S3やIAMの作成は、KROが作ったMRを見たAWS Providerが進めます。MRはManaged Resourceの略で、この例では「AWSリソースをKubernetesのAPIで管理するためのリソース」です。

開発者用ServiceAccountではStorageAppを作成・更新できますが、IAMのMRを作ったり、プラットフォーム設定のConfigMapを書き換えたりはできません。この拒否も実EKSで確認しました。

レプリカ数は1〜3、`storageId` は作成後に変更できない設定です。こちらも、禁止した変更が拒否されることと、1→2→1へのスケールが通ることを確認しています。

GitHub Actionsで動かしているのは、lint、テスト、イメージのビルド確認、kind上の検証です。今回のEKSへのデプロイは、手元のコマンドから行いました。[デプロイスクリプト](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab/blob/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/scripts/05-demo.sh)

## 作成順とReadyは、どこに書く？

KRO側には `ResourceGraphDefinition`、略してRGDを登録します。「StorageAppに何を入力できるか」と「そこから何を作るか」をまとめた定義です。

今回は次の6種類のMRを作り、Deployment、Service、ServiceAccountと組み合わせました。

| MR | 管理するもの |
|---|---|
| Bucket | S3バケット |
| BucketPublicAccessBlock | S3の公開アクセスをブロックする設定 |
| BucketServerSideEncryptionConfiguration | S3のデフォルト暗号化 |
| Role / RolePolicy | アプリ用IAMロールとS3アクセス権限 |
| PodIdentityAssociation | EKSのServiceAccountとIAMロールの関連付け |

RGDでは、例えばAssociationがRoleのARNを参照し、DeploymentがAssociationのIDを参照します。この参照から、KROが依存関係を組み立てます。アプリ用ポリシーの準備も待つよう、AssociationのannotationにはRolePolicyへの参照を置きました。

MRは `Ready=True` と `Synced=True` の両方を待ちます。Deploymentは、要求した数のレプリカが更新され、利用可能になるまで待つようにしました。

```yaml
# platform/storage-app.yaml の抜粋
- id: deployment
  readyWhen:
    - ${deployment.status.observedGeneration == deployment.metadata.generation}
    - ${deployment.status.?updatedReplicas.orValue(0) == deployment.spec.replicas}
    - ${deployment.status.?availableReplicas.orValue(0) == deployment.spec.replicas}
```

では、Podが「利用可能か」は何で決めるのか。ここはアプリのreadiness probeで、S3へ実際にアクセスして確かめます。

## まず、アプリからS3へ保存して読んでみる

アプリはGoで作った小さなHTTP APIです。大きな機能は付けず、ファイルの保存と取得だけにしました。

| API | やること |
|---|---|
| `GET /healthz` | プロセスが生きているかを返す。AWSにはアクセスしない |
| `GET /readyz` | S3の一時オブジェクトをPut / Get / Deleteし、内容を比べる |
| `PUT /objects/{key}` | 最大1 MiBのファイルを `uploads/` 配下に保存する |
| `GET /objects/{key}` | ファイルを取得する。なければ404を返す |

readinessは10秒周期を設定し、専用の `_health/` キーを使います。livenessはAWSに依存させず、S3の調子が悪いだけでプロセスを再起動しないようにしました。

通常の動作確認では、HTTPでバイナリをPUTし、GETしたファイルと元ファイルのSHA256を比べています。「200が返った」だけでなく、読み戻した中身まで一致しました。

![実CLI出力：StorageAppと6種類のMRがReady、HTTPで往復したファイルのSHA256が一致](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/screenshots/02-ready.jpg)

*スクショ1：StorageAppと6種類のMRがReadyになり、HTTPで往復したデータも一致しました。保存した実CLI出力をHTMLにして撮影した画面です。AWSコンソールではありません。以下の障害・復旧・保持・再接続のCLI画面も同じ方式で、アカウントIDを置換しています。*

AWSの認証にはPod Identityを使っています。アプリもProviderも短期認証情報で動き、長期アクセスキーは持たせていません。アプリではIMDSからの認証情報取得も無効にしています。

## 権限をわざと不足させたら、Readyはどうなる？

次は、動いているアプリのIAMロールに専用のDenyポリシーを足します。拒否したのは、ヘルスチェック用の `_health/*` に対する `s3:PutObject` です。

バケットやAssociationはそのままにして、S3へのヘルスチェックを失敗させます。このDenyは、Crossplaneが管理するRolePolicyとは別のポリシーとして追加しました。

![障害伝播の図：MRはReadyのまま、S3の権限不足がreadiness、Deployment、StorageAppへ伝わる](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/1c6671021a87992443426ad157cd0dc894fe1807/docs/diagrams/02-readiness.png)

*図2：S3の403がアプリのreadinessに伝わり、Deployment、StorageAppの状態も変わります。*

結果はこうでした。

| 確認したもの | Denyの前 | Denyが効いた後 |
|---|---|---|
| 6種類のMRのReady / Synced | すべてTrue | **すべてTrueのまま** |
| S3へのヘルスチェック | 成功 | PutObjectが403 / AccessDenied |
| Deployment | 1/1 | 0/1 |
| StorageApp | Ready=True | Ready=False、STATE=IN_PROGRESS |

![実CLI出力：MRはReady=Trueのまま、StorageAppはReady=False、S3 PutObjectは403](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/screenshots/03-failure.jpg)

*スクショ2：AWSのMRはすべてReadyなのに、アプリ側はReady=Falseになっています。*

readinessが失敗してDeploymentが0/1になるのは、Kubernetesの通常の動きです。今回確認したのは、RGDの `readyWhen` に書いたDeploymentの条件が効き、**StorageAppもReady=Falseになること**です。MRがReadyのままでも、Deploymentの条件を満たさなければStorageApp全体はReadyになりません。

この実験は、定義したReadyの条件が働くことの動作確認です。Denyの対象は `_health/*` のPutObjectだけなので、`uploads/*` のアクセス障害を検知できるかは未確認です。前節のHTTP Put/Getも、正常時の保存・取得を確認したものです。

Denyを外すと、Podを作り直すコマンドを実行せずに、StorageAppがReady=Trueへ戻りました。

![実CLI出力：Denyを除去した後、Deployment 1/1とStorageApp Ready=Trueへ復旧](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/screenshots/04-recovered.jpg)

*スクショ3：権限を戻した後。Deploymentも1/1へ戻りました。実験スクリプトは、終了時にも専用Denyを外します。*

ただ、S3を毎回チェックする分、リクエストは増えます。S3障害で全PodをNotReadyにするのがよいかも、アプリ次第です。自社で使うなら、どこまでをReadyに含めるかは先に決めておきたいところです。

> **追記メモ②：** 自社ならこのreadinessをどう使うか。常時チェックするか、作成時だけ疎通を試すか、別の監視に分けるかについて感想を足す。

## アプリを消したら、S3のデータも消える？

今回は、アプリとIAM、Pod Identity Associationは片付けつつ、S3のデータは残すことにしました。

S3関連の3種類のMRでは、`managementPolicies` に `Delete` を入れていません。

```yaml
spec:
  managementPolicies: [Observe, Create, Update, LateInitialize]
  providerConfigRef:
    name: aws
    kind: ProviderConfig
```

これでKubernetes上のMRが消えても、AWS上のバケットや設定は削除されません。バケットだけでなく、公開ブロックと暗号化の設定も残すようにしています。

![保持と再接続の図：アプリ削除後にS3を残し、同じstorageIdで再作成したPodから元のデータを読む](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/1c6671021a87992443426ad157cd0dc894fe1807/docs/diagrams/03-retention.png)

*図3：アプリを消し、同じstorageIdで作り直します。S3は残したものを使います。*

実際にStorageAppを削除すると、Deploymentも6種類のMRも消えました。それでもS3の元ファイルは残り、SHA256は一致。公開ブロック4項目とAES256のデフォルト暗号化も残っていました。

![実CLI出力：アプリとMRの削除後も、S3のデータと保護設定が残る](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/screenshots/05-retained.jpg)

*スクショ4：削除が終わり、まだアプリを作り直していない時点の記録です。*

続いて、同じ `storageId: demo` でStorageAppを作り直します。このラボでは、ラボ固有のprefixとstorageIdからバケット名を決めているので、同じ設定なら元のバケットへ接続します。

ファイルは再アップロードせず、**新しいPodのHTTP APIから元ファイルをGET**しました。次の3つでSHA256が一致しています。

- 最初に保存した元ファイル
- アプリ削除後にS3から取得したファイル
- 作り直したアプリからHTTP GETしたファイル

![実CLI出力：再作成したアプリから元のファイルを取得し、3つのSHA256が一致](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/screenshots/06-reconnected.jpg)

*スクショ5：新Podから元データを読めました。このPodのrestartCountは0でした。*

今回確認したのは、同一アカウント・同一ラボ設定での再接続です。別クラスタへの復旧や、任意の既存バケットの取り込みは試していません。保持したデータの誤更新まで防げるわけではないので、バックアップも別に考える必要があります。

## 実AWSに載せたら引っかかったところ

事前にはkind上でも確認しています。実際のKROとProviderのCRDを使いますが、AWS側のstatusは模擬するテストです。型や依存関係は確認できても、AWSの権限や反映タイミングは実環境で確かめる必要がありました。

### IAMロールを作る前のGetRoleが403になった

IAM Providerの権限をworkloadsパスに絞っていたところ、まだ存在しないロールを調べるGetRoleで止まりました。

今回はラボ名のprefixで絞ったrootパスのARNにも、`iam:GetRole` だけを追加すると先に進みました。ロールの作成・更新・削除はworkloadsパスに限定したままです。作成時に指定のpermissions boundaryを付ける条件も残しています。

GetRoleはRoleNameを入力に取るAPIです。[API仕様](https://docs.aws.amazon.com/IAM/latest/APIReference/API_GetRole.html) と [実際のエラー](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab/blob/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/evidence/iam-observe-error.txt) を残しました。追加した読み取り権限では、同じラボ名のProviderロールのメタデータも読めるようになる点は、変更として記録しています。

### Associationの作成にもGetRoleが必要だった

こちらはEKS Provider側です。PassRoleを許可していても、Associationの作成で次のエラーになりました。

```text
Caller does not have permission to perform iam:GetRole
```

対象workloadsパスの `iam:GetRole` を、PassRoleとは別のStatementに追加して解消しました。PassRole用の `iam:PassedToService=pods.eks.amazonaws.com` という条件は、GetRoleへまとめて付けないようにしています。

[AWSの実装例](https://aws.amazon.com/blogs/containers/how-to-manage-eks-pod-identities-at-scale-using-argo-cd-and-aws-ack/) にも、GetRoleとPassRoleを分けた例があります。[今回のエラー](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab/blob/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/evidence/association-error.txt) はこちらです。

### AssociationがReadyでも、直後のPodに認証設定が入っていなかった

Association作成直後のPodには、Pod Identity用の `AWS_CONTAINER_*` 環境変数と投影トークンが注入されていませんでした。同じテンプレートでPodを作り直すと注入され、Readyになりました。

AWSはAssociationの反映が結果整合的であると説明しています。今回の動きはその説明と合いますが、AWS内部のどこで遅れていたかまでは特定していません。[Association作成APIの説明](https://docs.aws.amazon.com/eks/latest/APIReference/API_CreatePodIdentityAssociation.html)

このラボでは、AWSが公開している認証用の環境変数とトークン投影をDeploymentに明示しました。

```yaml
# アプリコンテナのenvの抜粋
- name: AWS_CONTAINER_CREDENTIALS_FULL_URI
  value: http://169.254.170.23/v1/credentials
- name: AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE
  value: /var/run/secrets/pods.eks.amazonaws.com/serviceaccount/eks-pod-identity-token
```

トークンは `audience: pods.eks.amazonaws.com`、有効期間86400秒とし、読み取り専用でmountします。Kubernetes API用トークンの自動mountは無効のままです。[AWSのPod Identityの説明](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-how-it-works.html) に形式を合わせています。

これで認証情報を取得するための設定は最初からPodに入り、Associationの反映をSDKとreadinessの再試行で待てるようにしました。修正後の再作成では、手動でPodを作り直さずに元データを読めました。

この設定は今回のIPv4構成向けです。Agentや構成を変えるときには、このテンプレートも確認し直します。

## 使ったバージョンと、試すときの入口

| コンポーネント | 今回使った版 |
|---|---|
| KRO | 0.9.4 |
| Crossplane | 2.4.2 |
| AWS Provider（family / S3 / IAM / EKS） | 2.8.1 |
| EKS Kubernetes | v1.36.4-eks-cfb47f5（指定は1.36） |
| EKS platform | eks.14 |
| EKS Pod Identity Agent | v1.3.10-eksbuild.3 |
| eksctl / Helm | 0.230.0 / 3.22.0 |
| Go | 1.27.1 |

![実AWSコンソール：新規EKSがActive、Kubernetes 1.36](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/screenshots/01-eks-active.jpg)

*スクショ6：実AWSコンソール。Kubernetes 1.36の新規EKSがActiveになったところです。アカウント情報が出る部分は撮影範囲から外しています。*

ここは少しバージョンに注意が要ります。今回のMRは `s3.aws.m.upbound.io/v1beta1` のように **`.m.` が入るnamespaced版**です。使ったCRDでは、`providerConfigRef` にnameとkindを指定し、削除時の保持には `managementPolicies` を使います。古い例を混ぜる前に、その版のCRDを確認します。

チャートや検証用CRD、コンテナイメージはハッシュやdigestも保存しました。EKSアドオンは初回実行時に対応版を解決するため、次の実行で全く同じ版になるとは限りません。[実際のバージョン一覧](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab/blob/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/evidence/versions.json) はこちらです。

環境は `m7i.xlarge` 1台、NAT Gatewayと外部Load Balancerなしです。HTTPのユーザー認証は付けず、アプリにはClusterIPとlocalhostのport-forwardで接続しました。短時間の検証用の構成です。

試す場合は、次のコミットから始められます。記事の画像やコードへのリンクも、この版に固定しています。

```bash
git clone https://github.com/suzuki0430/kro-crossplane-eks-idp-lab.git
cd kro-crossplane-eks-idp-lab
git checkout 49a3bae7e3c6198f3a15caefa5adbd2f41d5b658
```

[READMEの準備手順](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab/blob/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/README.md#前提と準備) に沿って、SSOプロファイル、期待するアカウントID、リージョン、新しいLAB_ID、管理者のIPv4 /32を `.env` に設定します。その後の流れは次のとおりです。

```bash
# ローカルで確認
make check test
make graph

# EKSと、アプリを受け付ける仕組みを用意
make cluster
make bootstrap
make platform

# イメージをpushし、StorageAppを登録
make image
make demo

# 読み書き・権限・データ保持を試す
make verify
make verify-iam
make failure
make retention

# EKSなどを削除。S3は残す
make cleanup
```

EKS、EC2、EBS、public IPv4などの料金は発生します。今回、EKS作成は約14分33秒、cleanupは約12分52秒でした。1回の実行結果なので、所要時間の目安として見てください。初回アプリ作成には原因調査も含まれていたため、通常のデプロイ時間としては載せていません。

## 最後にEKSも片付ける

cleanupでは、先にStorageAppとMRを削除し終えてから、Provider用のIAMやEKSを消します。削除処理の途中で、その処理をするコントローラーや権限を先に消さないためです。

検証後はEKS、VPC、ネットワークインターフェース、EBS、関連IAM、ECRを削除しました。EC2もterminatedになっています。S3には39バイトの `uploads/probe.bin` を残し、EKS削除後に読み出したデータも元と一致しました。

![実AWSコンソール：S3に残るuploads/probe.bin](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/screenshots/07-s3-object-retained.jpg)

*スクショ7：実S3コンソール。残しておいた検証ファイルです。*

![実AWSコンソール：後片付け後の東京リージョンのEKS一覧は0件](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/screenshots/08-eks-deleted.jpg)

*スクショ8：実EKSコンソール。後片付け後のクラスタ一覧は0件です。関連リソースは [AWS APIの出力](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab/blob/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/evidence/cleanup.txt) でも照合しました。保持したS3には、ストレージ・リクエスト等の料金が引き続きかかります。*

## 自社で使うなら、次に何を決める？

今回、StorageAppを1つ登録してアプリとS3を用意し、権限不足をReadyへ返し、削除後もデータを残して再接続するところまで試せました。

ただ、これをそのまま社内に配ればIDPが完成、とはいきません。例えば今回の共有Namespaceでは他のStorageAppも編集でき、任意のイメージを指定できます。同じstorageIdを同時に使うことを止める仕組みもありません。

自社で使う前に決めたいのは、こんなところです。

- 誰がどのStorageAppを編集できるか。残したデータへ再接続できるのは誰か。
- どのイメージを動かしてよいか。アプリにどこまでAWS権限を渡すか。
- Readyで何を約束するか。使えないとき、開発者には何を見せるか。
- データをいつまで残すか。完全削除やバックアップ、別クラスタへの復旧をどうするか。
- KROとCrossplaneを併用する価値があるか。Crossplaneにまとめた場合と、定義の書きやすさや運用の手間をどう比べるか。

IAMシミュレーターでは、境界なしのロール作成や境界除去などが拒否されることも確認しました。ただ、別Namespaceや別ServiceAccountからのアクセスを、実AWS APIですべて試したわけではありません。確認したことと、まだ確認していないことは [権限のレビュー](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab/blob/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/security-review.md) に分けてあります。

> **追記メモ③：** 両方触って分かりやすかった点・複雑だった点、自社ならどこから始めたいかを書く。Crossplane単独版と比較するなら、何を見たいかもここへ。

## コードと検証記録

- [リポジトリと実行手順](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab/blob/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/README.md)
- [StorageAppの定義（RGD）](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab/blob/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/platform/storage-app.yaml)
- [検証結果・バージョン・所要時間](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab/blob/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/verification.md)
- [スクショの出典](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab/blob/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/screenshots/README.md)
- [権限の設定と試験範囲](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab/blob/49a3bae7e3c6198f3a15caefa5adbd2f41d5b658/docs/security-review.md)
