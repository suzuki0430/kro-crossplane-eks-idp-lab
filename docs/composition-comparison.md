# Crossplane Composition単独版の比較検証

2026-10-04、東京リージョンの新規EKS `idplab-cp1004a` で実施。
KROをインストールせず、同じStorageAppの入力でアプリとAWSリソースを作成できた。
比較対象は [2026-10-02のKRO併用版](verification.md)。別クラスタ・別時刻の実行であり、性能ベンチマークではない。

## 条件と実装

| 項目 | KRO併用版 | Composition単独版 |
|---|---|---|
| API定義 | KRO 0.9.4のRGD | namespaced XRD（apiextensions.crossplane.io/v2） |
| 合成処理 | RGDのテンプレートと参照 | Composition + function-go-templating 0.13.0 |
| Crossplane / AWS Provider | 2.4.2 / 2.8.1 | 同じ |
| Kubernetes | EKS 1.36.4 | EKS 1.36.4、platformVersion eks.14 |
| アプリイメージdigest | sha256:fe711ad2f32a287433df85ec66c39fee5201e8aae25ff14318d38a9c4241ab44 | 同じ |
| 開発者が指定した値 | storageId / image / replicas | 同じ（ECRのラボ別URLは異なる） |
| 作成する型 | native 3種類 + namespaced AWS MR 6種類 | 同じ |
| AWS認証・権限・S3保持 | Pod Identity / permissions boundary / Deleteを含めないS3 managementPolicies | 同じ |

Functionは [function.yaml](../platform/composition/function.yaml) でOCI index digestを固定。
追加の独自Functionやprovider-kubernetesは使っていない。
[環境と実際のcontroller一覧](evidence/composition/environment.txt) に、KROのCRDがないことも記録した。
入力の共通部分を比較しており、Crossplaneが追加する `spec.crossplane` やConditionsまで同一のAPIとは扱わない。
KROの `status.state` は単独版にはない。

定義は [xrd.yaml](../platform/composition/xrd.yaml)、[composition.yaml](../platform/composition/composition.yaml)、
[function.yaml](../platform/composition/function.yaml) を参照。
Composition選択はXRDの `enforcedCompositionRef` で固定する。
共通設定のConfigMapはpipelineの `requirements.requiredResources` で取得する。
このデモの対象Namespaceは `idp-lab` 固定で、任意Namespaceへ展開する汎用Compositionではない。

## 実AWSでの結果

| 確認 | 結果・証跡 |
|---|---|
| 初回作成・HTTP PUT/GET | [Ready](evidence/composition/ready.txt)：MR 6種類がReady/Synced=True、Deployment 1/1、39バイトのバイナリ往復が一致。404と開発者RBACも確認 |
| `_health/*` のPutObjectをDeny | [障害時](evidence/composition/failure.txt)：MRはTrueのまま、S3 403、Deployment 0/1、StorageApp Ready=False |
| Deny解除 | [復旧](evidence/composition/recovered.txt)：手動のPod再作成なしでReady=True |
| StorageApp削除 | [保持](evidence/composition/retained.txt)：nativeリソースとMR消滅後、元データ・公開ブロック4項目・AES256を確認 |
| 同じstorageIdで再作成 | [再接続](evidence/composition/reconnected.txt)：新Podから元ファイルをHTTP GET。再PUTせずに元データと一致 |
| APIの制約・更新 | [API検証](evidence/composition/api-contract.txt)：storageId変更、replicas 0/4を拒否。開発者SAで1→2→1に変更し、DeploymentとStorageAppに反映 |
| IAM境界 | [IAMシミュレーター](evidence/composition/iam-policy-simulation.txt)：既存の7項目を再実行。実APIでの拒否試験とは別 |

今回の元データ・HTTP応答・アプリ削除後・再接続後のSHA256：

```text
e4b50809a611331a16f92e69c71e764722afb8ea13a460a113fbafb6745abd4b
```

readinessの結果は、設定したDeployment条件がStorageAppへ反映されることを確認したもの。
`uploads/*` の障害検知能力や、KRO/CompositionがS3のデータプレーンを直接監視することは示していない。

## 書き換えて違ったところ

KROでは、Role ARNやAssociation IDなどの参照から依存関係を作る。
今回のGoテンプレート版では、AWS MRのReady/SyncedやARNを読み、初回にどのリソースを出力するかを明示した。
すべての型がまだ出力されていない段階でStorageAppがReadyにならないよう、9リソース全体のReady条件も返す。

ここでは「初回に待つ」と「作成済みのリソースを維持する」を分ける必要がある。
Composition Functionのdesired resourcesから以前の子リソースが消えると、Crossplaneはその子の削除を進める。
そのため、初回の依存条件を満たす場合 **または** 既にその子が存在する場合にテンプレートを出力する。
単に上流のReadyだけで出力を切り替えると、稼働後の一時的な上流障害でDeploymentまで削除対象になる。

[kindテスト](../tests/composition.sh) は実Crossplaneと実Functionを使い、AWSのstatusだけを模擬する。
段階的な作成、未完成時のReady=False、エラー反映、API制約、レプリカ反映に加え、
BucketのSyncedをFalseに戻してもDeploymentのUIDが変わらないことを確認した。
この上流障害の試験はローカルでのstatus模擬であり、実AWS障害を起こした試験とは区別する。

削除もKROの参照グラフと同じ順序を再現したわけではない。
単独版はCrossplaneの所有関係とKubernetesのGCを使う。共通スクリプトで子の消滅も待ち、
IAM等のfinalizer処理が終わる前にProviderやクラスタを消さないようにした。
依存関係に基づく厳密な逆順削除を保証するUsagesは、この比較版では定義していない。

## 観測した制約

- 作成・スケール変更中、StorageAppに `Responsive=False / WatchCircuitOpen` を観測した。
  [環境記録](evidence/composition/environment.txt) にConditionsを残している。
  最終的なReadyとスケール反映は確認できたが、即時に反映されるとは扱わない。
  この検証では原因の切り分けやチューニング、遅延の統計測定はしていない。
- Functionの記述方法はGo templatingを選んだ一例。Crossplane全体の記述量・難易度を代表しない。
- 新旧実装間での既存リソース移行、in-placeアップグレード、大量StorageApp、マルチテナント分離は未検証。
- 同じAPI名を使う2実装を同じクラスタへ併存させない。各実装には別のLAB_IDと新規EKSを使う。
- Provider/IAM/Pod Identityは共通なので、KROを外しても既存のAWS認証・権限設計が不要になるわけではない。

## 後片付け

2026-10-04 22:27 JSTに削除が完了し、[AWS APIで照合](evidence/composition/cleanup.txt) した。
Bootstrap・nodegroup・clusterの3つのCloudFormation stackがDELETE_COMPLETE。
VPC、ENI、subnet、EBS、関連IAM、ECRは残数0、記録したEC2はterminated、東京のEKS一覧は空だった。
S3には今回の39バイトの元ファイルを残し、EKS削除後もSHA256が一致した。
10月2日のKRO版の保持ファイルも再取得し、当時のSHA256から変わっていないことを確認した。
保持した2つのS3バケットは完全削除の対象にしていない。

## 再実行

`.env` に新しい `LAB_ID` と `COMPOSER=crossplane` を設定し、READMEの準備後に実行する。

```bash
make composition                  # AWSを使わないkindテスト
make cluster bootstrap platform
make image demo
make verify verify-api verify-iam
make failure retention
make cleanup                      # S3を保持
```

## 参考

- [Crossplane v2.4 Compositions](https://docs.crossplane.io/v2.4/composition/compositions/)
- [Crossplane v2.4 XRD](https://docs.crossplane.io/v2.4/composition/composite-resource-definitions/)
- [function-go-templating v0.13.0](https://github.com/crossplane-contrib/function-go-templating/tree/v0.13.0)
