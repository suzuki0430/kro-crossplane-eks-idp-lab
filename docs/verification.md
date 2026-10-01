# 検証記録

2026-10-01時点。ユーザーの指定で今回は実装のみ。追加の検証は延期する。
以下のローカル結果は、その指定を受ける前の実行記録であり、最終コード全体の検証完了を示すものではない。

| 項目 | 結果 |
|---|---|
| Go単体テスト、race detector、go vet | 成功 |
| HTTP / S3アダプタのカバレッジ | 90.4% / 87.8%（server起動部分を除く） |
| linux/amd64イメージビルド | 成功 |
| CloudFormation lint、ShellCheck、CRD SHA256 | 成功 |
| kind 1.36.4 + KRO 0.9.4 + Provider 2.8.1 CRD | 成功 |
| RGD型検査、依存Ready待ち、エラー表示 | 成功（AWS statusを模擬） |
| storageId変更拒否、レプリカ制約と更新 | 成功 |
| finalizerによる削除順序制御 | 成功 |
| GitHub Actions | 未実行。workflow_dispatchで手動実行可能 |
| 実EKS上のProviderとPod Identity | 未実行・延期 |
| 実S3のHTTP Put/Get、404、RBAC | 未実行 |
| 権限不足→Ready=False→復旧 | 未実行 |
| 削除時のS3保持・再接続 | 未実行 |
| 途中まで作成したEKSの後片付け | EKS / VPC等のCloudFormation stackはDELETE_COMPLETE。kindも削除済み |

kindではAWS Providerを動かさず、実CRDと実KROに対してManaged Resourceのstatusのみを模擬する。
これはIAM認証やAWSリソースのライフサイクルの証明にはならない。
実環境のアカウントID、IP、ARN、kubeconfig、ログはGit除外の `.local/` に保存する。

EKSコントロールプレーンの作成まで進んだ時点で検証延期の指示を受けた。
アプリ・S3・ワークロードIAMの作成や実AWSでの動作確認は行わず、作成済みインフラを削除した。
