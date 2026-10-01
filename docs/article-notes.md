# 記事用メモ

仮題: **KRO + Crossplane + EKSでS3付きアプリをセルフサービス化する――作成・Ready・削除から考えるIDP設計**

1. 開発者に渡すStorageApp APIを示す。image / storageId / replicasは適切な入力か。
2. 固定バージョンとnamespaced MRのAPI差分を説明する。
3. RGDの依存グラフとProviderの責務を図にする。
4. API投入から実S3へのHTTP読み書きを見せる。
5. PutObjectをDenyし、インフラReadyと実際に使える状態の違いを観測する。
6. アプリを削除し、データ・暗号化・公開ブロックが残ることを確認する。
7. 同じstorageIdで再接続する。
8. 権限、復旧、RGD更新、Crossplane v2単独との比較を、自社IDPの設計課題として整理する。

計測候補は、投入→Ready、Deny→Ready=False、権限復旧→Ready、削除完了までの時間。
実測・成功結果は `docs/verification.md` と `.local/` を基に追記し、事前に作らない。
