# IAM・認証設計のレビュー

2026-10-01。コード上のレビューであり、実AWSでの許可・拒否の検証は延期している。

| 対象 | 実装上の制限 | 実環境で確認する点 |
|---|---|---|
| S3 Provider | ラボの名前を持つバケットへの設定操作。GetObject / DeleteObjectを付与しない | Terraform由来のrefreshがこの権限で完了するか |
| IAM Provider | ラボのworkloadsパスに限定。CreateRoleに所定のpermissions boundaryを要求 | 境界なし・別境界での作成が拒否されるか |
| IAM Provider | DeleteRolePermissionsBoundary、境界ポリシー自体の編集を付与しない | 境界の除去が拒否されるか |
| EKS Provider | ラボのクラスタ・association ARNに限定。PassRoleはworkloadsパスとEKS Pod Identity宛てだけ | 別クラスタ・別パスのロールへの操作が拒否されるか |
| Providerの信頼ポリシー | クラスタARN・crossplane-system・各ProviderのServiceAccountに限定 | 別ServiceAccountで引き受けられないか |
| アプリの信頼ポリシー | クラスタARN・アプリNamespace・専用ServiceAccountに限定 | Pod Identityのsession tagsが期待どおりか |
| アプリの権限 | 自身のバケットのuploads / _healthを読み書き。Deleteは_healthだけ | uploadsの削除、別バケットへのアクセスが拒否されるか |
| 開発者RBAC | StorageAppの編集とPod情報の読み取り。MR・ConfigMap編集を付与しない | impersonationによる許可・拒否の確認 |

`make failure` はデモ用ロールへ専用のDenyインラインポリシーを追加し、EXIT trapでそのポリシーだけを除去する。
クラスタ削除前には作成したStorageAppと全対象MRの消滅を待ち、認証用ロールを先に削除しない。

この実装は敵対的マルチテナント環境を対象としない。同じNamespaceの開発者は他のStorageAppも編集でき、
任意のコンテナイメージを指定できる。データを所有者単位で隔離するには、チーム別Namespace / IAM境界 / admission policy /
イメージの許可制などの追加設計が必要。公開HTTP API向けのユーザー認証も実装していない。
