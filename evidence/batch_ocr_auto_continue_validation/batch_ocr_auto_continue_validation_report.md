# BatchOCR自動継続検証レポート

- 確認日時: 2026/6/20 17:57:20 JST
- ブランチ: feature/persistent-batch-ocr
- 検証対象: 2,000件BatchOCRJob完了後の任意自動継続
- 総合結果: PASS

## ケース結果

### 自動継続ON: 2,000件完了後に次の2,000件を作る
- 結果: PASS
- メッセージ: 次の2,000件ジョブ作成PASS
- Series状態: running
- 自動継続ON: true
- 次Job作成: true
- plannedCount: 2000
- AUTO_CONTINUE decision:
  - AUTO_CONTINUE decision
  - enabled=true
  - seriesEnabled=true
  - completedJobID=debug-auto-first-7F886B62-0E40-4FAA-975E-1BD9429BBF46
  - requestedLimit=2000
  - remainingCandidates=2000
  - thermal=nominal
  - lowPower=false
  - freeStorage=4000000000
  - appState=active
  - existingJobState=preparing
  - decision=startNextBatch
  - reason=created next 2,000 batch

### 自動継続ON: thermal fairでは低速次job作成
- 結果: PASS
- メッセージ: 次の2,000件ジョブ作成PASS
- Series状態: running
- 自動継続ON: true
- 次Job作成: true
- plannedCount: 2000
- AUTO_CONTINUE decision:
  - AUTO_CONTINUE decision
  - enabled=true
  - seriesEnabled=true
  - completedJobID=debug-auto-first-317037C1-FBFD-4344-9DC3-B0F580BFACCF
  - requestedLimit=2000
  - remainingCandidates=2000
  - thermal=fair
  - lowPower=false
  - freeStorage=4000000000
  - appState=active
  - existingJobState=preparing
  - decision=startNextBatch
  - reason=created next 2,000 batch

### 自動継続OFF: 次jobを作らない
- 結果: PASS
- メッセージ: OFF時の停止PASS
- 自動継続ON: false
- 次Job作成: false
- plannedCount: 2000
- AUTO_CONTINUE decision:
  - AUTO_CONTINUE decision
  - enabled=false
  - seriesEnabled=false
  - completedJobID=debug-auto-off-first-60D71D37-8134-4EF4-934A-EBECF27A202D
  - requestedLimit=2000
  - remainingCandidates=unknown
  - thermal=nominal
  - lowPower=false
  - freeStorage=4000000000
  - appState=active
  - existingJobState=completed
  - decision=skip
  - reason=autoContinueEnabled is false

### 自動継続: 未読取0件で停止
- 結果: PASS
- メッセージ: 0件ジョブ未作成PASS
- Series状態: completedNoMoreTargets
- 自動継続ON: true
- 次Job作成: false
- plannedCount: 2000
- AUTO_CONTINUE decision:
  - AUTO_CONTINUE decision
  - enabled=true
  - seriesEnabled=true
  - completedJobID=debug-auto-none-first-EA84FEEB-D418-4989-8367-F6DA21CA29A8
  - requestedLimit=2000
  - remainingCandidates=0
  - thermal=nominal
  - lowPower=false
  - freeStorage=4000000000
  - appState=active
  - existingJobState=completed
  - decision=stopNoTargets
  - reason=no unread candidates

### 自動継続: thermal seriousで停止
- 結果: PASS
- メッセージ: 発熱一時停止PASS
- Series状態: pausedDeviceCondition
- 自動継続ON: true
- 次Job作成: false
- plannedCount: 2000
- AUTO_CONTINUE decision:
  - AUTO_CONTINUE decision
  - enabled=true
  - seriesEnabled=true
  - completedJobID=debug-auto-thermal-first-1BA3BCCE-29E7-40AD-B97F-8E8CA5BA28BE
  - requestedLimit=2000
  - remainingCandidates=unknown
  - thermal=serious
  - lowPower=false
  - freeStorage=4000000000
  - appState=active
  - existingJobState=completed
  - decision=pause
  - reason=端末温度が高いため、自動継続を一時停止しています。

### 自動継続: low powerで停止
- 結果: PASS
- メッセージ: 低電力一時停止PASS
- Series状態: pausedDeviceCondition
- 自動継続ON: true
- 次Job作成: false
- plannedCount: 2000
- AUTO_CONTINUE decision:
  - AUTO_CONTINUE decision
  - enabled=true
  - seriesEnabled=true
  - completedJobID=debug-auto-low-first-3BF02C04-948A-4A6E-8212-B99F8617ECF1
  - requestedLimit=2000
  - remainingCandidates=unknown
  - thermal=nominal
  - lowPower=true
  - freeStorage=4000000000
  - appState=active
  - existingJobState=completed
  - decision=pause
  - reason=低電力モードのため一時停止しています。

### 自動継続: 途中jobがある場合は既存jobを再開
- 結果: PASS
- メッセージ: 既存job優先PASS
- Series状態: idle
- 自動継続ON: true
- 次Job作成: false
- plannedCount: 2000
- AUTO_CONTINUE decision:
  - AUTO_CONTINUE decision
  - enabled=true
  - seriesEnabled=true
  - completedJobID=-
  - requestedLimit=0
  - remainingCandidates=unknown
  - thermal=nominal
  - lowPower=false
  - freeStorage=4000000000
  - appState=active
  - existingJobState=pausedBackground
  - decision=pause
  - reason=existing paused job has priority

## 確認事項

- 2,000件完了直後の `finish -> handleAutoContinueAfterCompletion -> prepareNextAutoContinueBatch` 経路で次Job作成を確認。
- 自動継続ONかつ端末状態が良い場合だけ、次の2,000件Jobを作ることを確認。
- 自動継続OFFでは次Jobを作らないことを確認。
- thermal fairでは停止せず次Jobを作ることを確認。
- thermal serious / low powerでは一時停止し、次Jobを作らないことを確認。
- 未読取0件では0件Jobを作らず完了状態にすることを確認。
- 既存の一時停止Jobがある場合は、新規Jobではなく既存Job再開を優先することを確認。
- 元写真・元動画を削除・変更する処理は含まない。
