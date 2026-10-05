# KROとCrossplaneは両方いる？ EKSでS3付きアプリを作って比べてみた

> 編集用の下書きです。「追記メモ」は自分の感想を書き足す場所として残しています。公開するときに置き換えるか、削除してください。

この前、[Cloud Native Platform Engineering Japan Meetup #3 — Platform Engineering Kaigi 前夜祭スペシャル](https://ocgroups.dev/cncf/group/bqd97by/event/c3zf287) で登壇したのですが、もう一つのHENNGE様の発表が「Building elegant platform with KRO」でした。

KROについては7月のKubeConで関連セッションを聞いてから気になっていたのですが、そこに今回の発表が重なり、自分でも触ってみようと思いました。

自社のIDPへの示唆にもなるかと思い、KROとCrossplaneを組み合わせて試すことにしました。

題材は、S3にファイルを保存する簡単なアプリです。
「このイメージでアプリを動かしたい」と伝えたら、Deploymentだけでなくそのアプリ用のS3とIAMも一緒に用意してくれる形です。

こちらがリポジトリです。

https://github.com/suzuki0430/kro-crossplane-eks-idp-lab

> **追記メモ①：** HENNGEの発表やKubeConのセッションで特に気になった点、自社の状況と重なった点があれば、ここに1〜2文足す。

## KROとCrossplaneは両方必要か

今回の目的なら、KROの併用は必須ではありません。後半ではKROを入れないEKSも用意し、CrossplaneのCompositionで同じアプリを動かしてみました。

| 構成                            | 今回やりたいことができるか                                                                                                                   |
| ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| KROだけ                         | DeploymentやServiceをまとめて作れる。ただし、KRO本体にはS3やIAMを操作する機能がないため、AWSを操作するコントローラーなどを別途足す必要がある |
| Crossplane v2 + AWS Provider + Function | KROなしで実現できる。独自APIとCompositionを定義し、DeploymentとAWSのリソースをまとめて作る                                                   |
| KRO + Crossplane + AWS Provider | 最初に試した構成。独自APIとリソース同士のつなぎ込みをKROに、AWS操作をProviderに任せる                                                              |

今回は、イベントをきっかけに気になった組み合わせを動かしてみることにしました。KROで開発者向けのAPIを作り、AWS操作をCrossplaneのProviderに任せる形です。機能上、両方が必要だったから選んだわけではありません。まずはCompositionを使わないKRO併用版から見ていきます。

## 誰に何を任せたか

今回の入口は `StorageApp` というカスタムリソースです。開発者がこれを1つ作ると、KROが必要なKubernetesリソースを作ります。そのうちAWS向けのものを、ProviderがAWSへ反映します。

![構成図：開発者のStorageAppをKROがKubernetesリソースとMRへ展開し、CrossplaneのAWS ProviderがAWSリソースを管理する](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/1c6671021a87992443426ad157cd0dc894fe1807/docs/diagrams/01-architecture.png)

| 担当                      | 今回やってもらうこと                                                   |
| ------------------------- | ---------------------------------------------------------------------- |
| KRO                       | StorageAppのAPIを作り、必要なリソースと依存関係、Readyの条件を定義する |
| Crossplane + AWS Provider | S3、IAM、Pod Identity AssociationをAWS上に作り、状態を同期する         |
| EKS                       | コントローラーとアプリを動かす。Pod IdentityでAWSの認証情報を渡す      |
| eksctl / CloudFormation   | EKS本体やProvider用のIAMなどを先に用意する                             |

EKS本体はStorageAppを作る前に準備します。今回セルフサービス化したのは、用意済みのEKSに載せるアプリとそのアプリ用のAWSリソースです。

## アプリはどうデプロイしたか

今回はターミナルからコマンドで実行しました。ポータル画面やGitOpsによるデプロイは作っていません。

EKSとコントローラーを準備した後、次のスクリプトを使います。

```bash
# アプリのイメージをビルドし、ECRへpushする
bash scripts/04-image.sh

# StorageAppを登録し、Readyになるまで待つ
bash scripts/05-demo.sh
```

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

```bash
kubectl apply \
  --as=system:serviceaccount:idp-lab:developer-demo \
  -f .local/demo.json
```

コマンドが登録するのはStorageAppです。その後、KROがDeploymentなどを作り、Kubernetesの標準コントローラーがPodを起動します。S3やIAMの作成は、KROが作ったMRを見たAWS Providerが進めます。

開発者用ServiceAccountではStorageAppを作成・更新できますが、IAMのMRを作ったり、プラットフォーム設定のConfigMapを書き換えたりはできません。

## 作成順とReadyは、どこに書く？

KRO側には`ResourceGraphDefinition`(RGD)を登録します。「StorageAppに何を入力できるか」と「そこから何を作るか」をまとめた定義です。

今回は次の6種類のMRを作り、Deployment、Service、ServiceAccountと組み合わせました。

| MR                                      | 管理するもの                             |
| --------------------------------------- | ---------------------------------------- |
| Bucket                                  | S3バケット                               |
| BucketPublicAccessBlock                 | S3の公開アクセスをブロックする設定       |
| BucketServerSideEncryptionConfiguration | S3のデフォルト暗号化                     |
| Role / RolePolicy                       | アプリ用IAMロールとS3アクセス権限        |
| PodIdentityAssociation                  | EKSのServiceAccountとIAMロールの関連付け |

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

## アプリからS3へ保存して読んでみる

アプリはGoで作った小さなHTTP APIです。

| API                  | やること                                                 |
| -------------------- | -------------------------------------------------------- |
| `GET /healthz`       | プロセスが生きているかを返す。AWSにはアクセスしない      |
| `GET /readyz`        | S3の一時オブジェクトをPut / Get / Deleteし、内容を比べる |
| `PUT /objects/{key}` | 最大1 MiBのファイルを `uploads/` 配下に保存する          |
| `GET /objects/{key}` | ファイルを取得する。なければ404を返す                    |

readinessは10秒周期を設定し、専用の `_health/` キーを使います。livenessはAWSに依存させず、S3の調子が悪いだけでプロセスを再起動しないようにしました。

通常の動作確認では、HTTPでバイナリをPUTし、GETしたファイルと元ファイルのSHA256を比べています。

![実CLI出力：StorageAppと6種類のMRがReady、HTTPで往復したファイルのSHA256が一致](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/d0055ec1707e0ff02ef38f6d47fc2722541e0c35/docs/screenshots/02-ready.jpg)

AWSの認証にはPod Identityを使っています。アプリもProviderも短期認証情報で動き、長期アクセスキーは持たせていません。

## 権限をわざと不足させたときの挙動

動いているアプリのIAMロールに専用のDenyポリシーを足します。拒否したのは、ヘルスチェック用の `_health/*` に対する `s3:PutObject` です。

バケットやAssociationはそのままにして、S3へのヘルスチェックを失敗させます。

![障害伝播の図：MRはReadyのまま、S3の権限不足がreadiness、Deployment、StorageAppへ伝わる](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/1c6671021a87992443426ad157cd0dc894fe1807/docs/diagrams/02-readiness.png)

結果はこうなりました。

| 確認したもの              | Denyの前   | Denyが効いた後                 |
| ------------------------- | ---------- | ------------------------------ |
| 6種類のMRのReady / Synced | すべてTrue | すべてTrueのまま               |
| S3へのヘルスチェック      | 成功       | PutObjectが403 / AccessDenied  |
| Deployment                | 1/1        | 0/1                            |
| StorageApp                | Ready=True | Ready=False、STATE=IN_PROGRESS |

![実CLI出力：MRはReady=Trueのまま、StorageAppはReady=False、S3 PutObjectは403](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/d0055ec1707e0ff02ef38f6d47fc2722541e0c35/docs/screenshots/03-failure.jpg)

readinessが失敗してDeploymentが0/1になるのは、Kubernetesの通常の動きです。今回確認したのは、RGDの `readyWhen` に書いたDeploymentの条件が効き、StorageAppもReady=Falseになることです。MRがReadyのままでも、Deploymentの条件を満たさなければStorageApp全体はReadyになりません。

Denyを外すとStorageAppがReady=Trueへ戻りました。

![実CLI出力：Denyを除去した後、Deployment 1/1とStorageApp Ready=Trueへ復旧](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/d0055ec1707e0ff02ef38f6d47fc2722541e0c35/docs/screenshots/04-recovered.jpg)

> **追記メモ②：** 自社ならこのreadinessをどう使うか。常時チェックするか、作成時だけ疎通を試すか、別の監視に分けるかについて感想を足す。

## アプリを消したらS3のデータも消えるか

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

実際にStorageAppを削除するとDeploymentも6種類のMRも消えました。それでもS3の元ファイルは残りSHA256は一致。公開ブロック4項目とAES256のデフォルト暗号化も残っていました。

![実CLI出力：アプリとMRの削除後も、S3のデータと保護設定が残る](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/d0055ec1707e0ff02ef38f6d47fc2722541e0c35/docs/screenshots/05-retained.jpg)

続いて、同じ `storageId: demo` でStorageAppを作り直します。このラボでは、ラボ固有のprefixとstorageIdからバケット名を決めているので、同じ設定なら元のバケットへ接続します。

ファイルは再アップロードせず、新しいPodのHTTP APIから元ファイルをGETしました。次の3つでSHA256が一致しています。

- 最初に保存した元ファイル
- アプリ削除後にS3から取得したファイル
- 作り直したアプリからHTTP GETしたファイル

![実CLI出力：再作成したアプリから元のファイルを取得し、3つのSHA256が一致](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/d0055ec1707e0ff02ef38f6d47fc2722541e0c35/docs/screenshots/06-reconnected.jpg)

## KROを外して、Compositionだけでも試した

ここまでだと「KROでもできた」としか分からないので、KROを入れないEKSも作りました。今度はCrossplaneのXRDでStorageAppのAPIを定義し、CompositionからGoテンプレートのFunctionを呼びます。DeploymentなどはCrossplane v2が直接扱えるため、provider-kubernetesも使っていません。

Crossplane 2.4.2、AWS Provider 2.8.1、アプリのイメージdigestは揃えました。単独版で追加したFunctionは `function-go-templating v0.13.0` です。StorageAppに渡す `storageId`、`image`、`replicas` も同じ形にしています。

![比較図：同じStorageAppの入力から、KROのRGDとCrossplaneのCompositionでリソースを作る](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/d0055ec1707e0ff02ef38f6d47fc2722541e0c35/docs/diagrams/04-comparison.png)

結果として、今回試した動作はどちらでも実現できました。

| 確認したこと | KRO併用版 | Composition単独版 |
|---|---|---|
| StorageAppからアプリ・S3・IAMを作る | 成功 | 成功 |
| HTTPでファイルをPUT / GETし、ハッシュを比較 | 一致 | 一致 |
| `_health/*` のDenyと解除 | Ready=False→True | Ready=False→True |
| storageIdの変更、replicas: 4 | 拒否 | 拒否 |
| replicasを1→2→1にする | 反映 | 反映 |
| アプリ削除後にS3と保護設定を残す | 保持 | 保持 |
| 同じstorageIdで再作成し、元ファイルをGET | 一致 | 一致 |

![実CLI出力：KROなしのComposition版で、6種類のMRとアプリがReadyになりHTTPの往復が成功](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/d0055ec1707e0ff02ef38f6d47fc2722541e0c35/docs/screenshots/09-composition-ready.jpg)

### 違ったのは、待つ処理の書き方

KROでは、リソース間の参照から依存関係を組み立ててくれます。今回のGoテンプレート版では、「BucketとRoleがReadyならRolePolicyを出す」「AssociationとS3の保護設定がReadyならDeploymentを出す」と条件を書きました。

ただし、上流のReadyだけで出力を切り替えると困ります。作成済みのDeploymentがFunctionの出力から消えると、Crossplaneはそれを削除対象として扱うためです。

そこで、**初回は依存先を待ち、すでに作ったリソースは出力に残す**ようにしました。kind上でBucketのSyncedをFalseに戻し、DeploymentのUIDが変わらないことも確認しています。この試験はAWSのstatusを模擬したもので、実AWSの障害試験とは分けています。

また、まだ一部のリソースしか出力していない段階でReadyにならないよう、9リソース全体の条件をFunctionから返しました。KROの `readyWhen` に相当する判断を、こちらにも用意した形です。

### S3を残せるのは、どちらもProvider側の設定

単独版でも、StorageAppを消したあとに同じstorageIdで作り直し、新しいPodから元ファイルを読めました。再アップロードはしていません。

![実CLI出力：Composition版でも、元データ・アプリ削除後・再接続後のSHA256が一致](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/d0055ec1707e0ff02ef38f6d47fc2722541e0c35/docs/screenshots/10-composition-reconnected.jpg)

ここはKRO固有の機能ではなく、両方が同じMRの `managementPolicies` を使った結果です。ただし、削除順まで同じではありません。単独版は所有関係とKubernetesのGCで子を片付けるため、スクリプト側でもMRの消滅を待っています。KROの依存グラフと同じ逆順削除を再現したわけではありません。

これで「このアプリを作るために両方必要か」には、必要ない、と答えられます。Crossplaneだけなら、独自APIの定義もリソースの組み立てもCrossplane側に揃えられます。ただし、今回の単独版にはFunctionも必要です。KROを外した分だけ運用が楽になるかは、今回の検証では分かりません。

一方、**今回のStorageAppの定義を読み、変更していくなら、KROありの方が扱いやすそうです。** リソース間のつながりは参照式で、待つ条件は `readyWhen` で追えます。Goテンプレート版では、初回に依存先を待つ処理や、作成済みのリソースを出力に残す処理まで自分で書く必要がありました。この分岐をテンプレートに書かずに済む点に、KROを足す利点がありそうです。

これは主に、基盤側で定義を書く人にとっての違いです。アプリ開発者がStorageAppに値を入れてapplyする操作は、どちらでも同じです。また、GoテンプレートはCompositionの書き方の一例なので、別のFunctionを使う場合や、既存のCompositionを流用できる場合にも同じ評価になるとは限りません。長期的な保守のしやすさは、これから確かめたいところです。

単独版では `Responsive=False / WatchCircuitOpen` も観測し、スケール変更の反映に待ちがありました。最終的な反映は確認しましたが、原因の切り分けと運用時の評価は残っています。KRO版は10月2日、単独版は10月4日の別クラスタでの検証なので、所要時間で性能を比べることもしていません。[実装と比較の記録](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab/blob/d0055ec1707e0ff02ef38f6d47fc2722541e0c35/docs/composition-comparison.md) に、条件と各段階のログをまとめました。

## 実AWSに載せたら引っかかったところ

以下は、最初のKRO併用版で引っかかった点です。修正したIAMとアプリの認証設定は、Composition版でもそのまま使っています。

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

## 最後にEKSも片付ける

cleanupでは、先にStorageAppとMRを削除し終えてから、Provider用のIAMやEKSを消します。削除処理の途中で、その処理をするコントローラーや権限を先に消さないためです。

KRO版・Composition版とも、検証後はEKS、VPC、ネットワークインターフェース、EBS、関連IAM、ECRを削除しました。EC2もterminatedになっています。S3はラボごとに残し、それぞれの39バイトの `uploads/probe.bin` をEKS削除後に読み出して、元データと比べました。

*以下のAWSコンソール画像は10月4日に英語表示で撮り直しました。S3の画像は10月2日のKRO版で残したファイル、EKS一覧は両方の検証環境を片付けた後の状態です。*

![実AWSコンソール：S3に残るuploads/probe.bin](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/d0055ec1707e0ff02ef38f6d47fc2722541e0c35/docs/screenshots/07-s3-object-retained.jpg)

![実AWSコンソール：後片付け後の東京リージョンのEKS一覧は0件](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/d0055ec1707e0ff02ef38f6d47fc2722541e0c35/docs/screenshots/08-eks-deleted.jpg)

## 自社で使うなら、次に何を決める？

今回、StorageAppを1つ登録してアプリとS3を用意し、権限不足をReadyへ返し、削除後もデータを残して再接続するところまで試せました。

ただ、これをそのまま社内に配ればIDPが完成、とはいきません。例えば今回の共有Namespaceでは他のStorageAppも編集でき、任意のイメージを指定できます。同じstorageIdを同時に使うことを止める仕組みもありません。

自社で使う前に決めたいのは、こんなところです。

- 誰がどのStorageAppを編集できるか。残したデータへ再接続できるのは誰か。
- どのイメージを動かしてよいか。アプリにどこまでAWS権限を渡すか。
- Readyで何を約束するか。使えないとき、開発者には何を見せるか。
- データをいつまで残すか。完全削除やバックアップ、別クラスタへの復旧をどうするか。
- 今回触ったRGDとCompositionのどちらをチームで保守したいか。更新や障害対応まで含めて試すには何が必要か。

IAMシミュレーターでは、境界なしのロール作成や境界除去などが拒否されることも確認しました。ただ、別Namespaceや別ServiceAccountからのアクセスを、実AWS APIですべて試したわけではありません。確認したことと、まだ確認していないことは [権限のレビュー](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab/blob/d0055ec1707e0ff02ef38f6d47fc2722541e0c35/docs/security-review.md) に分けてあります。

> **追記メモ③：** RGDの参照とCompositionの条件分岐、どちらが自分には読みやすかったか。自社ならどこから始めたいか、今回の比較を読んだ感想を足す。
