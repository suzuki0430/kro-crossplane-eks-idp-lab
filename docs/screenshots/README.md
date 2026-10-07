# 検証スクリーンショット

Qiitaとdev.toで共通の画像を使えるよう、画像内の説明と画面の表示言語は英語に統一しています。
AWSコンソールの画面と、保存したCLI出力をブラウザで表示した画面を区別して記録しています。

| 画像 | 出典・確認内容 | 検証日・撮影日（日本時間） |
|---|---|---|
| [01-eks-active.jpg](01-eks-active.jpg) | AWSコンソール：**Composition単独版**の新規EKS `idplab-cp1004a` がActive。Kubernetes 1.36 | 2026-10-04 |
| [02-ready.jpg](02-ready.jpg) | [KRO併用版：準備完了](../evidence/ready.txt)。6種類のMRとアプリが準備完了となり、HTTPで保存・取得したバイナリが一致 | 検証：2026-10-02／英語画面の撮影：2026-10-04 |
| [03-failure.jpg](03-failure.jpg) | [KRO併用版：権限不足](../evidence/failure.txt)。準備状態の確認に使うPutObjectを拒否すると、MRはReadyのままアプリが準備未完了になる | 検証：2026-10-02／英語画面の撮影：2026-10-04 |
| [04-recovered.jpg](04-recovered.jpg) | [KRO併用版：復旧](../evidence/recovered.txt)。検証用のDenyを解除すると準備完了へ戻る | 検証：2026-10-02／英語画面の撮影：2026-10-04 |
| [05-retained.jpg](05-retained.jpg) | [KRO併用版：データ保持](../evidence/retained.txt)。アプリ削除後も元データ、公開アクセスのブロック設定、暗号化設定が残る | 検証：2026-10-02／英語画面の撮影：2026-10-04 |
| [06-reconnected.jpg](06-reconnected.jpg) | [KRO併用版：再接続](../evidence/reconnected.txt)。新しいPodから再アップロードせずに元ファイルを取得 | 検証：2026-10-02／英語画面の撮影：2026-10-04 |
| [07-s3-object-retained.jpg](07-s3-object-retained.jpg) | AWSコンソール：**元のKRO併用版**の `uploads/probe.bin`（39バイト）が残り、更新日時も10月2日のまま | 撮影：2026-10-04 |
| [08-eks-deleted.jpg](08-eks-deleted.jpg) | AWSコンソール：両方のラボを片付けたあと、東京リージョンのEKSクラスタが0件 | 撮影：2026-10-04 |
| [09-composition-ready.jpg](09-composition-ready.jpg) | [Composition単独版：準備完了](../evidence/composition/ready.txt)。KROを入れずに同じアプリの動作を確認 | 2026-10-04 |
| [10-composition-reconnected.jpg](10-composition-reconnected.jpg) | [Composition単独版：再接続](../evidence/composition/reconnected.txt)。3つのSHA256がすべて一致 | 2026-10-04 |

CLI出力の画像は、`scripts/render-evidence.py` で保存済みのテキストを表示し、ブラウザで撮影したものです。
10月2日のCLI記録、時刻、状態、エラー文、ハッシュは変更せず、周囲の説明だけを英語にしています。
表示用の `composition-ready.txt` と `composition-reconnected.txt` は、`docs/evidence/composition/` 内の対応する記録をコピーしたものです。

画像01・07・08は、AWSコンソールの表示言語を英語にして撮り直しています。
アカウント・セッション情報は撮影範囲から除外し、CLI記録内のアカウントIDは公開前に `ACCOUNT_ID` へ置換しています。
画像01に写っているのは、削除済みの10月2日のクラスタではなく、10月4日に用意した比較用クラスタです。

画像は検証時点の記録です。現在の環境の状態は示していません。
詳細は [KRO併用版の検証記録](../verification.md)、[Composition単独版との比較](../composition-comparison.md)、
[Composition単独版の片付け記録](../evidence/composition/cleanup.txt) を参照してください。
