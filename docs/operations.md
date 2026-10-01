# 運用メモ

## 状態の確認

```bash
export KUBECONFIG="$PWD/.local/kubeconfig"
kubectl get rgd storage-app -o yaml
kubectl -n idp-lab get storageapp demo -o yaml
kubectl -n idp-lab get managed
kubectl -n idp-lab get pods
kubectl -n idp-lab get events --sort-by=.lastTimestamp
kubectl -n idp-lab logs deployment/storage-demo
kubectl get providers
kubectl -n crossplane-system get pods
```

MRの `Synced=False` はProviderの操作エラー。StorageAppの `storageMessage` / `identityMessage` /
`associationMessage` と元のMRのConditionsを確認する。
クラウド側がReadyでもS3読み書きに失敗すれば、PodとStorageAppのReadyがFalseになる。
反映にはprobe周期・Deployment更新・KRO reconcileによる遅延がある。
Readyは直近の観測結果であり、将来の可用性やバックアップ完了の保証ではない。

## 障害実験が中断した場合

`experiment-failure.sh` はEXIT時にDenyを削除する。強制終了などで残った場合、対象アカウントを確認して、
ラボの `idplab-LAB_ID-demo` ロールから **`idplab-deny-health-probe` というインラインポリシーだけ**を削除する。
AdministratorAccessなどへの置き換えで復旧しない。

## 保持と再接続

アプリ削除ではPod Identity AssociationとIAMが片付く。S3のMRも消えるが、バケット・暗号化・公開ブロックはAWSに残る。
削除完了後、同じstorageIdのStorageAppが同じバケット名で再接続する。
この機能は同一アカウント・同一ラボ設定を対象とし、汎用のバケットimport機能ではない。

## 後片付け

`make cleanup` は、所有タグ照合→StorageApp削除→残存MR確認→Bootstrap削除→EKS削除の順。
Providerのfinalizerが完了するまでコントローラを残す。未知のStorageAppや残存MRがあれば停止する。
finalizerを強制削除して成功扱いにしない。S3一覧は `.local/retained-buckets.json` に残る。
保持S3にはストレージ等の料金が継続する。データの完全削除はこのスクリプトに含めない。

クラスタ作成途中に失敗したらCloudFormationイベントを確認する。アプリ作成前であれば、対象名とタグを確認して
`eksctl delete cluster --name idplab-LAB_ID --region REGION --wait` でeksctl側を片付ける。
Bootstrap作成済みならそのstackも削除する。アプリ作成済みなら、先にアプリとMRの削除を完了させる。
スクリプトは専用 `.local/kubeconfig` を使い、普段のkubectl設定を切り替えない。

## 更新

`versions.env`、Helmハッシュ、イメージdigest、Go依存、同じProviderタグのCRDをまとめて更新する。
`make check test graph` の後、別LAB_IDで実EKS上の作成・失敗・保持・削除を確認する。
Helm更新だけでCRDも更新済みと仮定しない。既存IDPのin-placeアップグレードは本ラボの対象外。
