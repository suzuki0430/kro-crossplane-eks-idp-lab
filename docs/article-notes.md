# Qiita記事用メモ

仮題: **KRO + Crossplane + EKSでS3付きアプリをセルフサービス化する――「作成できた」と「使える」を分けて検証した**

実測の出典は [検証記録](verification.md)、挿入画像は [スクショ一覧](screenshots/)。
本文は以下の順に組み立てると、API設計・運用・実AWS特有の問題がつながる。

## 1. 開発者にはStorageAppを1つ渡す

`spec.storageId`、`spec.image`、`spec.replicas` の3項目を見せる。
開発者のServiceAccountで作成・更新し、IAMのMRやplatform用ConfigMapは変更できない。
storageIdの変更とreplicas=4はAPIサーバーが拒否することも実EKSで確認した。

構成図はREADMEのMermaidを利用する。今回のCrossplaneはAWS Providerの実行基盤として使い、
KROが独自APIとリソース間の依存関係を組み立てる。CrossplaneのCompositionは使っていない。
「KROが必須」と一般化せず、自社IDPでどの層にAPI・依存・運用契約を持たせるかという比較材料にする。

## 2. バージョンとAPIを固定する

KRO 0.9.4 / Crossplane 2.4.2 / AWS Provider 2.8.1 / EKS 1.36。
Providerのnamespaced MRは `*.aws.m.upbound.io`。S3保持にはmanagementPoliciesからDeleteを除く。
EKSアドオンは実行時に互換版を解決し、取得した版を保存した。記事にはversions.jsonの実測値を載せる。

挿入: `01-eks-active.jpg`。EKSコントロールプレーンがActive、1.36、Standard supportである実コンソール。

## 3. 作成と本当のReadyを確認する

S3・IAM Role/Policy・Pod Identity Association・Deployment・Serviceまで依存順に作る。
PodのreadinessはS3の一時オブジェクトをPut/Get/Deleteして内容一致を確認する。
HTTP経由でバイナリをアップロードし、ダウンロード結果とのSHA256一致を示す。

挿入: `02-ready.jpg`。保存した実CLI出力をブラウザで表示した画面であることを明記する。

## 4. インフラReadyでもアプリは使えない状態を作る

アプリの `_health/*` に対するPutObjectを一時的にDenyする。
6種類のMRのReady/SyncedはすべてTrueのまま、S3は403、Deploymentは0/1、StorageAppはReady=Falseになった。
Denyを取り除くと、Pod再作成コマンドなしでReady=Trueに戻った。

挿入: `03-failure.jpg` と `04-recovered.jpg`。記事の中心となる比較。
`Ready` の意味を、クラウドリソースの存在・コントローラーの同期・アプリの実利用可能性に分けて説明する。

## 5. 削除はデータのライフサイクル設計

StorageAppの削除でPod Identity・IAM・Kubernetesリソースを片付ける。
S3のMRも消えるが、AWS上にはバケット・データ・公開ブロック・暗号化が残る。
同じstorageIdで再作成し、元のファイルを新PodからHTTP GETできた。再アップロードはしていない。
最後はEKSまで削除し、保持対象のS3と検証結果を残す。

挿入: `05-retained.jpg` と `06-reconnected.jpg`。S3コンソールのオブジェクト画面も補助に使う。
保持はバックアップではない。保持期限・所有権・再接続権限・別クラスタへの復旧は別の設計課題。

## 6. kindだけでは分からなかった3つの注意点

1. 存在しないIAM RoleのObserveが、パス限定GetRoleで403になった。同じラボ名のrootパスにGetRoleだけ追加。
2. Pod Identity Association作成にも対象RoleのGetRoleが必要だった。EKS Providerにworkloadsパス限定で追加。
3. AssociationのReady直後のPodで認証設定の注入が間に合わなかった。同じ設定でPodを再作成すると動作した。
   最終実装ではAWSの公開仕様に沿った環境変数と投影トークンをDeploymentへ明示し、再作成時も動作確認した。

詳細・一次資料・修正前のエラーは [verification.md](verification.md#実awsで見つかった3点と修正) を引用する。
初回の約507秒は調査と修正を含むため、通常のプロビジョニング性能として紹介しない。

## 7. 自社IDPへの宿題

- APIの所有権: Namespace、storageIdの一意性、誰が同じデータへ再接続できるか。
- 権限: 任意イメージを許可するか、Pod Identityを使う主体をどう管理するか。
- 状態: S3操作を伴うreadinessの頻度・リクエスト数、障害時のエラーの見せ方。
- データ: 保持期間、バックアップ、削除承認、管理クラスタ喪失後の復旧。
- 更新: RGD・Provider・アプリの段階的更新、互換性試験、ロールバック。

共有Namespaceの学習デモであり、敵対的マルチテナントの安全性を証明したとは書かない。
IAMシミュレーションの拒否結果と、実AWS APIで確認した動作を区別する。
