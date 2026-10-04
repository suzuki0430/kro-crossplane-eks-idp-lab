# Qiita・dev.to記事共通の図

2026-10-02・10-04の実装とAWS検証記録をもとにした説明図。スクリーンショットとは区別する。
本文挿入用のPNGと、文字・線・配置を編集できるSVGを同じ名前で保存する。
図中のタイトル・ラベル・注記とSVGの代替説明は英語に統一し、Qiitaとdev.toで同じ画像を使う。
言語ごとの説明は記事本文・キャプション・代替テキストで補う。

| 図 | 説明 | 編集用 |
|---|---|---|
| [01-architecture.png](01-architecture.png) | KRO・Crossplane・EKSの責務と、管理経路・データ経路。厳密なRGD依存グラフではない | [SVG](01-architecture.svg) |
| [02-readiness.png](02-readiness.png) | `_health/*` のPutObject拒否がアプリ側のReadyへ伝播し、MRはTrueを維持する観測 | [SVG](02-readiness.svg) |
| [03-retention.png](03-retention.png) | StorageApp削除、S3保持、同じIDでの再接続、元データの照合 | [SVG](03-retention.svg) |
| [04-comparison.png](04-comparison.png) | 同じ入力を持つKRO併用版とComposition単独版の実装の違い | [SVG](04-comparison.svg) |

PNGはSVGを2倍の寸法でラスタライズしたもの。フォントはArial（代替はHelvetica、sans-serif）。
SVGは外部画像・スクリプトを含まない。PNGを書き出し直す場合は、Arialを使える
SVG対応エディター等から幅2560pxで出力し、文字化け・はみ出しを確認する。

図は実測値の説明のために作成しており、AWSコンソールやコントローラーの画面を模したものではない。
根拠は [検証記録](../verification.md)、[RGD](../../platform/storage-app.yaml)、[IAMレビュー](../security-review.md) を参照。
