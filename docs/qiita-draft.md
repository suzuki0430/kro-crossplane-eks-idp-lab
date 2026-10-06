# KROとCrossplaneは両方いる？ EKSでS3付きアプリを作って比べてみた

> 編集用の下書きです。

この前、[Cloud Native Platform Engineering Japan Meetup #3 — Platform Engineering Kaigi 前夜祭スペシャル](https://ocgroups.dev/cncf/group/bqd97by/event/c3zf287) で登壇したのですが、もう一つのHENNGE様の発表が「Building elegant platform with KRO」でした。

KROについては7月のKubeConで関連セッションを聞いてから気になっていたのですが、そこに今回の発表が重なり、自分でも触ってみようと思いました。

自社のIDPでも使えそうか知りたくて、KROとCrossplaneを組み合わせて試すことにしました。

題材は、S3にファイルを保存する簡単なアプリです。
「このイメージでアプリを動かしたい」と伝えたら、Deploymentだけでなくそのアプリ用のS3とIAMも一緒に用意してくれる形です。

こちらがリポジトリです。

https://github.com/suzuki0430/kro-crossplane-eks-idp-lab

HENNGEの発表では、Platform Teamがリソースのひな形となるRGDを用意し、開発者は小さなYAMLを1つ書くだけでアプリとインフラを作る構成が紹介されていました。Kubernetesの細かい知識を開発者に求めない、という方針です。

Q&AではCrossplane Compositionも試したうえで、定義のシンプルさを理由にKROを選んだと説明されていました。普通のKubernetesのYAMLに近い感覚で書ける、という話です。今回も、同じアプリを作れるかだけでなく、基盤側で定義を書いたり直したりするときに何が違うのかを見ていきます。

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

各リソースを準備完了と判断する条件は、KROの`readyWhen`に書きます。

S3やIAMのMRでは、Providerが「利用可能」と報告する`Ready=True`と、直近の同期処理が成功したことを示す`Synced=True`の両方を確認します。[MRの状態の説明](https://docs.crossplane.io/latest/managed-resources/managed-resources/#conditions)

KROは次の3条件がすべて成立したら、このDeploymentを準備完了と判断します。

```yaml
# platform/storage-app.yaml の抜粋（説明コメントを追加）
- id: deployment
  readyWhen:
    # Deploymentコントローラーが最新の設定を認識している
    - ${deployment.status.observedGeneration == deployment.metadata.generation}
    # 最新のPodテンプレートに一致するPod数が指定数と同じ
    - ${deployment.status.?updatedReplicas.orValue(0) == deployment.spec.replicas}
    # readinessなどの条件を満たした利用可能なPod数が指定数と同じ
    - ${deployment.status.?availableReplicas.orValue(0) == deployment.spec.replicas}
```

`.?updatedReplicas.orValue(0)`は、作成直後などでその項目がまだない場合に0として扱う書き方です。`availableReplicas`にも同じ処理を入れています。

`availableReplicas`には古いPodも含まれるため、この3条件だけでローリング更新の完了までは保証していません。[Deploymentの各項目の定義](https://kubernetes.io/docs/reference/kubernetes-api/apps/deployment-v1/#DeploymentStatus)

## アプリ経由でS3の読み書きを確認する

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

ここまでだと「KROでもできた」としか分からないので、KROを入れないEKSも作りました。今度はCrossplaneのXRDでStorageAppのAPIを定義し、Compositionを使って必要なリソースを作ります。

ここからは、KROを使わないこの構成を「Composition版」と呼び、先ほどの「KRO併用版」と比べます。

Compositionでは、FunctionというプログラムがStorageAppの入力値や既存リソースの状態を見て、作成・維持するリソースの一覧を返します。Crossplaneはその一覧に合わせてリソースを管理します。

今回は公開されている `function-go-templating` を使い、DeploymentやMRの定義をGoテンプレートに書きました。このFunctionはEKS内のPodとして動きます。

DeploymentなどはCrossplane v2が直接扱えるため、provider-kubernetesも使っていません。

Crossplane 2.4.2、AWS Provider 2.8.1、アプリのイメージdigestは揃えました。Composition版で追加したFunctionは `function-go-templating v0.13.0` です。StorageAppに渡す `storageId`、`image`、`replicas` も同じ形にしています。

![比較図：同じStorageAppの入力から、KROのRGDとCrossplaneのCompositionでリソースを作る](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/d0055ec1707e0ff02ef38f6d47fc2722541e0c35/docs/diagrams/04-comparison.png)

結果として、今回試した動作はどちらでも実現できました。

| 確認したこと | KRO併用版 | Composition版 |
|---|---|---|
| StorageAppからアプリ・S3・IAMを作る | 成功 | 成功 |
| HTTPでファイルをPUT / GETし、ハッシュを比較 | 一致 | 一致 |
| `_health/*` のDenyと解除 | Ready=False→True | Ready=False→True |
| storageIdの変更、replicas: 4 | 拒否 | 拒否 |
| replicasを1→2→1にする | 反映 | 反映 |
| アプリ削除後にS3と保護設定を残す | 保持 | 保持 |
| 同じstorageIdで再作成し、元ファイルをGET | 一致 | 一致 |

![実CLI出力：KROなしのComposition版で、6種類のMRとアプリがReadyになりHTTPの往復が成功](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/d0055ec1707e0ff02ef38f6d47fc2722541e0c35/docs/screenshots/09-composition-ready.jpg)

### 依存関係とReadyの条件を比べる

KRO併用版では、リソース同士の参照で依存関係をつなぎ、`readyWhen`で準備完了の条件を書きました。例えばDeploymentからAssociationのIDを参照すると、KROがAssociationの準備を待ってDeploymentを作ります。

Composition版では、Goテンプレートに「AssociationとS3の保護設定がReadyならDeploymentを一覧に加える」と書きました。初回の作成順を、この条件分岐で制御しています。

作成後の扱いも必要でした。Functionが返す一覧からDeploymentが消えるとCrossplaneが削除してしまうため、依存先が一時的にReadyでなくなっても、作成済みのDeploymentは一覧に残します。

StorageApp全体をReadyにする条件もFunctionに書きました。必要な9リソースが揃っているか、MRがReady/Synced=Trueか、Deploymentが指定したレプリカ数で稼働しているかを確認します。

今回比べたComposition版は、Goテンプレートを使った実装の一例です。Composition版では`WatchCircuitOpen`の表示やスケール変更の反映待ちもありましたが、原因はまだ調べきれていません。別の日・別クラスタで試したため、性能は比較していません。[比較の記録](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab/blob/d0055ec1707e0ff02ef38f6d47fc2722541e0c35/docs/composition-comparison.md)に条件とログを残しています。

IAMやPod Identityの設定でつまずいた点は、[AWSでの検証記録](https://github.com/suzuki0430/kro-crossplane-eks-idp-lab/blob/d0055ec1707e0ff02ef38f6d47fc2722541e0c35/docs/verification.md#実awsで見つかった3点と修正)にまとめました。

### Composition版でもS3は残った

Composition版でも、StorageAppを削除したあとにS3のファイルが残りました。同じstorageIdで作り直すと、再アップロードせずに元のファイルを取得できました。

S3関連のMRでは、KRO併用版と同じく`managementPolicies`に`Delete`を入れていません。そのため、MRを削除してもProviderはAWS上のバケットや保護設定を削除しません。

![実CLI出力：Composition版でも、元データ・アプリ削除後・再接続後のSHA256が一致](https://raw.githubusercontent.com/suzuki0430/kro-crossplane-eks-idp-lab/d0055ec1707e0ff02ef38f6d47fc2722541e0c35/docs/screenshots/10-composition-reconnected.jpg)

## さいごに

今回のアプリとS3はCrossplaneだけでも作れました。
開発者がStorageAppをapplyする操作はどちらも同じでしたが、基盤側で依存関係や待つ条件を書く部分が違いました。
今回の定義なら、参照と`readyWhen`で追えるKROの方が扱いやすそうです。
