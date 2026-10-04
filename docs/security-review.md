# IAM・認証設計のレビュー

2026-10-02。コードレビューと実AWS検証の範囲を分けて記録する。

| 対象 | 実装上の制限 | 今回の確認 |
|---|---|---|
| S3 Provider | ラボ名のバケット設定操作。GetObject / DeleteObject / DeleteBucketを付与しない | 実AWSで作成・refresh・保持が成功 |
| IAM Providerの読み取り | workloadsパスに加え、初回Observe用にラボ名のrootパスへGetRoleだけ許可 | 初回403を記録し、追加後に実Createが成功。別ラボ名のGetRoleはシミュレーションで拒否 |
| IAM Providerの書き込み | workloadsパス限定。CreateRoleに指定のpermissions boundaryを要求 | 実ロールの境界設定を確認。境界なし・パス外CreateRoleはシミュレーションで拒否 |
| IAM Providerの境界保護 | DeleteRolePermissionsBoundaryと境界ポリシー編集を付与しない | 境界除去はシミュレーションで拒否。別境界の付与試験は未実施 |
| EKS Provider | ラボのcluster/association ARN、workloadsパスのGetRole、Pod Identity宛てPassRole | 実Association作成・削除が成功。別クラスタ・別パスへの実操作は未試験 |
| Providerの信頼 | クラスタARN・crossplane-system・専用ServiceAccountのsession tagsを要求 | 3種類のProviderがPod Identityで実操作。別ServiceAccountからの引き受け拒否は未試験 |
| アプリの信頼 | クラスタARN・Namespace・専用ServiceAccountを要求 | 実S3アクセス成功。静的キーなし、IMDS無効。別Namespaceからの拒否試験は未実施 |
| アプリの権限 | 自身のbucketのuploads / _healthを読み書き。Deleteは_healthだけ | 実Put/Get、readinessのPut/Get/Deleteが成功。明示Denyで403とReady=Falseを確認。uploads削除・別bucketアクセスの実拒否試験は未実施 |
| 開発者RBAC | StorageApp編集とPod情報の読み取り | impersonationで作成・レプリカ変更が成功、IAM MR作成とConfigMap変更は拒否 |

IAMシミュレーションの7項目は [実行記録](evidence/iam-policy-simulation.txt) を参照。
認証付きの実AWS API呼び出しをすべての拒否条件で試したわけではない。

アプリの認証用volumeは、AWSが公開するPod Identityの投影トークン形式を使用する。
audienceは `pods.eks.amazonaws.com`、有効期間は86400秒、mountは読み取り専用。
`automountServiceAccountToken: false` によりKubernetes API用トークンは自動mountしない。
エンドポイントは本ラボのIPv4構成向け。IPv6や将来のAgent仕様変更では見直す。

`make failure` はデモ用ロールへ専用のDenyインラインポリシーを追加し、EXIT trapでそのポリシーだけを除去する。
クラスタ削除前にはStorageAppと全対象MRの消滅を待ち、Provider用ロールを先に削除しない。

この実装は敵対的マルチテナント環境を対象としない。同じNamespaceの開発者は他のStorageAppも編集でき、
任意のコンテナイメージを指定できる。チーム別Namespace、IAM境界、admission policy、イメージ許可制、
storageIdの所有権・一意性などは自社IDPへの採用時に設計する。公開HTTP向けユーザー認証も実装していない。

## Composition版のRBAC

2026-10-04にCrossplane 2.4.2の固定Helm chartのClusterRoleと、合成後のIAMを確認した。
標準chartはCrossplane本体に、Deployment・Service・ServiceAccount・ConfigMap・Secret等の
クラスタ全体の管理権限を付与する。AWS MRについてはProviderインストール時のRBAC aggregationが権限を追加する。
NamespaceのRoleを追加しても、既にあるClusterRoleの権限は狭まらない。
そのため独自の重複RBACは配布せず、専用の検証クラスタで標準権限を使用した。

kind上でも、Crossplane SAがdefault NamespaceへDeploymentを作成できることを確認する。
AWS Providerを動かさずCRDだけ使うkindテストでは、[テスト専用RBAC](../tests/composition-rbac.yaml) で6型のMR権限を代替する。
これはAWS環境に適用しない。
実AWSで開発者SAによるStorageApp作成・スケールを確認し、IAM MR作成とConfigMap変更は拒否した。
XRDは `enforcedCompositionRef` でComposition選択を固定する。ただしStorageAppの所有権や任意イメージの制約を追加するものではない。

Goテンプレートは管理者が配布し、開発者のimageはYAMLとしてquoteする。storageIdはAPIの形式・不変制約を通る。
Functionのパッケージをdigest固定し、FunctionへAWS認証情報を渡さず、AWS操作は既存Providerに任せる。
共通IAMの7項目も [シミュレーターで再検証](evidence/composition/iam-policy-simulation.txt) した。
