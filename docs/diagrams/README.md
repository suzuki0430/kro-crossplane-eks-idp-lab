# Qiita・dev.to記事共通の図

2026-10-02・10-04の実装とAWS検証記録をもとにした説明図。スクリーンショットとは区別する。
本文挿入用のPNGと、文字・線・配置を編集できるSVGを同じ名前で保存する。
図中のタイトル・ラベル・注記とSVGの代替説明は英語に統一し、Qiitaとdev.toで同じ画像を使う。
言語ごとの説明は記事本文・キャプション・代替テキストで補う。

| 図 | 説明 | 編集用 |
|---|---|---|
| [01-architecture.png](01-architecture.png) | KRO・Crossplane・EKSの責務と、管理経路・データ経路。厳密なRGD依存グラフではない | [draw.io](01-architecture.drawio) / [SVG](01-architecture.svg) |
| [02-readiness.png](02-readiness.png) | `_health/*` のPutObject拒否がアプリ側のReadyへ伝播し、MRはTrueを維持する観測 | [SVG](02-readiness.svg) |
| [03-retention.png](03-retention.png) | StorageApp削除、S3保持、同じIDでの再接続、元データの照合 | [SVG](03-retention.svg) |
| [04-comparison.png](04-comparison.png) | 同じ入力を持つKRO併用版とComposition単独版の実装の違い | [SVG](04-comparison.svg) |

PNGはSVGを2倍の寸法でラスタライズしたもの。フォントはArial（代替はHelvetica、sans-serif）。
SVGは外部画像・スクリプトを含まない。01-architectureは公式アイコンのSVGを埋め込んでいる。
PNGを書き出し直す場合は、Arialを使えるSVG対応エディター等からSVGの2倍の寸法で出力し、
文字化け・はみ出しを確認する。01-architectureは2800 × 2480px、それ以外は幅2560px。

図は実測値の説明のために作成しており、AWSコンソールやコントローラーの画面を模したものではない。
根拠は [検証記録](../verification.md)、[RGD](../../platform/storage-app.yaml)、[IAMレビュー](../security-review.md) を参照。

## 公式アイコンを使った構成図

01-architectureは2026-10-06にAWS・Kubernetes・Crossplaneの公式素材で作り直した。
KRO、StorageApp、MRは文字で示し、独自に描いた図形を公式ロゴとして扱っていない。
S3は1つだけ描き、アプリからのデータアクセスとProviderからのAWS API操作の両方を同じS3へ接続した。

編集元は [01-architecture.drawio](01-architecture.drawio)。draw.ioで File → Open from → Device から開く。
文字、アイコン、箱、矢印は個別に編集でき、箱を移動すると中の文字とアイコンも移動する。
SVGにも同じdraw.ioのXMLを埋め込んでいるため、SVGをdraw.ioに読み込んで編集することもできる。
書き出し時は明るい背景、画像の埋め込み、Arialを使い、SVGとPNGを両方更新する。

使用素材の配布元、バージョン、ライセンスは [icons/README.md](icons/README.md) に記載。
原本のSHA256と配布元のURLは [icons/sources.json](icons/sources.json) に保存した。
