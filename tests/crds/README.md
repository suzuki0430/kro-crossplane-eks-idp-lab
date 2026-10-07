# バージョンを固定したAWS ProviderのCRD

ここにあるCRD（カスタムリソースの定義）は、`crossplane-contrib/provider-upjet-aws` の
`v2.8.1` タグの `package/crds/` から取得した、変更を加えていないスキーマです。
各ファイルのハッシュは `tests/crds.sha256` に記録しています。

取得元：[AWS Provider v2.8.1のCRD](https://github.com/crossplane-contrib/provider-upjet-aws/tree/v2.8.1/package/crds)

配布元のプロジェクトのライセンスはApache-2.0です。このディレクトリの [LICENSE](LICENSE) を参照してください。
これらのCRDをインストールするのは、スキーマ検証用の使い捨てクラスタだけです。
EKSには、実際のCrossplane Providerパッケージから同じAPIを導入します。
