# 旧核心退役与验收承接

<!-- Simplified Chinese documentation is explicitly requested by the user on 2026-09-12. -->

本轮直接删除旧会话／执行 SQL 仓库、旧应用协议、固定厂商路线、旧上下文构造器及工具注册器。生产源码现在只有新日志运行时与独立领域端口。没有保留旧解码、迁移、包装器或第二套运行时。宏观契约见[核心方案](../architecture/AGENT_CORE_PROPOSAL.md)，当前执行证据见[验证记录](AGENT_CORE_VERIFICATION.md)。

`MiraCore` 中的身份、Workspace、TokenUsage、JSON/schema、通用模型角色与状态继续由新契约使用。Thinking 控制、价格资料、价格来源、端点匹配与费用估算均归 `MiraProviders`；核心工具目录只检查逻辑身份，HTTP 名称转换冲突由 HTTP 准备阶段拒绝。

2026-09-14 用户确认核心重建按收缩范围收尾；本表未关闭的产品边界继续保留，**不再作为当前 Goal 的完成前置条件，也不自动继续执行**。完成范围见[收尾说明](AGENT_CORE_COMPLETION.md)。

## 原生测试目标的直接改写

原有四个旧架构测试文件已直接改用当前服务，删除旧库、旧应用和旧 Provider 替身。完整运行证据见[验证记录](AGENT_CORE_VERIFICATION.md)。

| 测试文件 | 已承接的行为与实际限制 |
|---|---|
| `MiraSettingsTests/ProviderConnectionSettingsModelTests.swift` | 隔离真实库覆盖空密钥拒绝、无隐式测试的保存、启停失败基线／草稿、CAS、取消过期测试、目录逻辑选择稳定性和 whitespace；新组合另覆盖密钥读取、关闭排空和迟到结果。通知先于保存返回的精确交错和原生焦点仍未单独验收 |
| `MiraPlatformTests/ConversationSelectionTests.swift` | 覆盖页面复用、草稿／阅读位置、缓存淘汰后的重读、维护失效、并发选择、无路线首次发送保留草稿，以及连接关闭后的路线刷新不重读已挂载消息页。并发选择使用真实调度，未对每种迟到次序建立独立 gate；这不是持久日志索引或大库性能证明 |
| `MiraPlatformTests/EverydayMemoryBaselineTests.swift` | 保留 32 场景中英语料和 JSON 报告，使用当前 `SessionUserEvidence` 合成证据验证宿主 triage；只证明乐观合成提取结果下的规则行为，不证明 LLM 提取／召回质量 |
| `MiraPlatformTests/EverydayMemoryLiveTests.swift` | 显式 opt-in 后才使用隔离库、内存凭据和真实 HTTP 模块；默认跳过。离线设置测试覆盖显式上下文限制、同模型双预设和不读取模型凭据。真实模型未运行；当前提取作业无结果时报告 `unavailable` 与未完成 mismatch，不伪造 negative case 成功 |

`WorkspaceEditorModelTests`、现有本地化和费用展示测试继续保留。测试数值变化不替代行为承接；没有恢复兼容接口或将旧测试文件从工程中排除。

## 验收承接方式

31 个旧架构测试／夹具文件中的 233 个测试声明随旧接口退役；6 个费用测试已直接改到新冻结路线，并移入 Provider 测试目标。这里的数字是源代码中的声明数，不是参数化测试执行数。没有通过 Package.swift 排除测试、跳过测试或引入兼容夹具来获得构建成功。当前正式包执行全部可用测试。

新测试验证的是下表所列新边界，不能仅凭同领域套件存在就声称逐条覆盖旧实现。原生设置、历史提示与规模方面的缺口仍须验收。下方保留完整旧测试名称，供后续按产品行为核对；它不是兼容实现或旧测试的源代码副本。原始断言可从提交 `8a33de0` 的对应路径查阅。

| 原边界 | 新架构的验收入口 | 当前限制 |
|---|---|---|
| 用户消息与排队执行原子接纳，取消、确认丢失、单活动执行 | `AgentApplicationRuntimeIntegrationTests`、`SessionRuntimeTests`、`SessionJournalTests` | 宿主已直接切换，原生窗口并发发送的完整交错验证待后续验收 |
| 工具派发、配对、结果顺序、审批、额度、超时、重复回执 | `AgentToolExecutorIntegrationTests`、`SessionToolApprovalTests`、`RuntimeServicesTests`、`AgentToolPolicyCompositionTests`、`AgentExecutionKernelIntegrationTests` | 不保留旧 ToolPort 或专用记忆审批器 |
| 上下文隔离、预算、原始证据、工具续接与思考重放 | `AgentContextTests`、`JournalAgentHistoryReaderTests`、`AgentToolEvidenceTests`、`ThinkingProtocolTests`、`AgentModelOutputTests` | 宿主内置提示及原生呈现待验收 |
| 草稿、取消、中断、恢复与终态唯一性 | `AgentModelDraftTimerTests`、`AgentExecutionRecoveryIntegrationTests`、`AgentLibraryRestorationTests`、`SQLiteBusinessReceiptStoreTests` | 无真实断电实验 |
| 配置 CAS、模型池原子保存、绑定与冻结复核 | `SQLiteAgentModelSettingsTests`、`AgentModelRouteResolverTests`、`HTTPModelConfigurationProviderTests` | 原生表单已直接接入，组合测试覆盖草稿测试与显式保存；完整原生编辑／取消交互仍待验收 |
| 手动／明确记忆、作用域、来源政策与引用 | `JournalMemoryStoreTests`、`MemoryWorkflowTests`、`MemoryRememberHandlerTests`、`MemoryModuleTests`、`RecordedContextSourcesTests` | 历史状态查询与宿主刷新已实现，完整原生外观仍待验收 |
| 后台提取、自然记忆演变、预算、消费者与撤销 | `JournalMemoryExtractionStoreTests`、`JournalMemoryExtractionCommitTests`、`MemoryExtractionWorkflowTests`、`MemoryExtractionConsumerTests`、`MemoryExtractionWorkerTests` | 生产工作组与捕获设置已接通，真实模型提取质量另行验收 |
| 遗忘后的业务／正文清理、传递排除、保留历史及阻止复活 | `MemoryForgetWorkflowTests`、`MemoryMaintenanceAdmissionTests`、`SessionPrivacyMaintenanceTests`、`SQLiteMemoryArchiveTests`、`SQLiteMemoryExtractionArchiveTests` | 不能把这些测试当作历史提示 UI 验收 |
| 知识导入、当前版本搜索、只读工具、精确引用与撤权 | `JournalKnowledgeStoreTests`、`JournalKnowledgeSearchTests`、`KnowledgeWorkflowTests`、`KnowledgePrivacyWorkflowTests`、`KnowledgeBlobMaintenanceTests` | 原生引用读取已接通，完整来源窗口交互与大库性能待测 |
| 全库归档、严格当前格式、来源／投影重建、故障清理 | `SQLiteLibraryArchiveTests`、`SQLiteDomainLibraryArchiveTests`、`SQLiteLibraryRestorerTests`、`FileSessionArchiveTests` 及领域归档套件 | 显式库切换及 namespace 通知退役已有组合验证，原生文件面板交互待验收 |
| 缓存／思考不重复计费、未知计数、端点约束和历史价格冻结 | Provider `ModelCostTests`、`HTTPModelConfigurationProviderTests.priceProvenanceIsFrozenLocallyAndNeverSentOnTheWire` | 执行检查器已显示完整执行汇总及尝试级费用；独立后台提取已接入[分页状态和全部尝试用量](../architecture/AGENT_EXTRACTION_QUERIES.md)，区分实际调用与预算扣减；完整原生矩阵继续验收 |
| SQL 旧版本迁移与旧表内部结构 | 当前格式拒绝测试由 `SessionJournalTests`、严格归档及各独立存储 integrity 测试负责 | 旧 schema 编号及迁移行为属于已废弃架构，不重建 |

## 后续产品验收（本次 Goal 外）

1. 历史记忆状态已接通[新查询](../architecture/AGENT_MEMORY_HISTORY.md)：从 journal 原请求与当前领域状态生成无正文提示，覆盖 updated、superseded、archived、expired、unavailable 及其他生命周期；选择限定一个会话。已完成遗忘的原计划支持保留回复的 forgotten 提示，严格引用和重放仍拒绝已排除执行。领域、真实流程和宿主刷新已有自动验证；原生外观与长期静止页面的到期刷新仍需单独验收。
2. 新能力探测服务已接通注册目录、原子候选快照、合成输入、实际请求期限／排空和保存 CAS，并验证未知能力探测与失败重测。原生 Test、连接草稿临时凭据和结果保存已接入新服务，完整交互仍待验收；不得以服务测试通过替代完整用户流程。原生 Test 与激活编辑使用新记录，不恢复旧 ProbeObservation。
3. 当前规模基准：10,000 条记忆、50,000 个片段、100,000 条消息／1,000 个会话，20 个 Markdown 文件，每文件 2,500 个 4 KiB 片段。热操作每项先预热 5 次、再测 30 个样本；记忆预取与完整上下文构造 P95 ≤ 300 ms，知识检索 P95 ≤ 500 ms，候选扫描 ≤ 20,000。搜索包含英文、中文两字／三字／标题、混合语言、代码路径、转义字面量及阴性查询，不能只有计时而不验命中语义。原 2 GiB 数据库上限、重开代理指标、可选大库备份往返要按新的 Business.sqlite／日志／正文／投影分别报告，不把旧 SQL 的低成本重开数字沿用到扫描 journal 的实现。
4. macOS 的消息页、阅读位置、流式思考、取消、引用、审批、设置、备份入口和关闭／重开；UI 直接消费新运行时及领域服务。程序包通过不替代原生验收。iOS 仍不实现。

## 退役测试清单

以下路径相对于 `Packages/MiraKit/Tests`，对应删除前提交 `8a33de0`。列表保留测试名用于追踪产品不变量，不声称所有旧断言已一一重写。

### MiraCoreTests/ContextBuilderTests.swift

- `thinkingReplayIsBoundToModelConnectionEndpointAndCredential`
- `rejectsUnknownCapabilitiesAndUnsafeEndpoints`
- `retryHistoryUsesSuccessfulReplacementAndCurrentInputOnce`
- `isolatesWorkspaceAndBlocksOversizedInputBeforeSending`
- `builtInPromptUsesEnglishLanguagePolicyAndPreservesChineseInput`

### MiraCoreTests/FaultInjectingStore.swift

仅旧协议测试夹具，无独立测试声明。

### MiraCoreTests/KnowledgeApplicationTests.swift

- `defaultLocalOnlySourceDoesNotReachModelAndCrossWorkspaceChunkCannotLeak`
- `grantedSourceRunsSearchOpenReadAndPersistsExactCitationAudit`
- `knowledgeFlowSurvivesApplicationReopenAndBackupRestore`
- `sourceUpdateKeepsOldCitationAndSearchesOnlyCurrentVersion`
- `revokingSourcePurgesSuspendedDerivedReplyAndLeavesNewConversationUsable`
- `deletingSourcePurgesMultiTurnDerivedHistoryAndExcludesItFromLaterHistory`

### MiraCoreTests/KnowledgePrefetchApplicationTests.swift

- `ordinaryMarkdownQuestionPrefetchesCurrentChunkAndAuditsCitation`
- `localOnlySourceIsExcludedFromAutomaticPrefetch`

### MiraCoreTests/KnowledgeToolTests.swift

- `registersBoundedReadOnlyToolsWithClosedSchemas`
- `searchOpenAndReadChunkReturnExactCitationsAndRecordUsage`
- `openingMetadataDoesNotAuthorizeCitationUntilChunkRead`
- `rejectsInvalidOptionalVersionAndDirectExtraArguments`
- `rejectsMismatchedLiveContextAndRevokedSource`

### MiraCoreTests/MemoryApplicationTests.swift

- `aNewConversationUsesOnlyCurrentAuthorizedMemories`
- `forgettingDuringGenerationClearsDerivedBodiesAndPreventsLaterRecall`

### MiraCoreTests/MemoryApprovalTests.swift

- `directAuthorizationRequiresAnAnchoredCompletePrefix`
- `approvalRequestUsesInvocationAsStableIdentity`
- `denialDoesNotLeaveAPendingRequestOrGrant`
- `cancellationBeforeAndDuringWaitResumesExactlyOnceAndCleansUp`
- `approvalGrantBindsExactProposalAndIsSingleUse`
- `concurrentApprovalRequestsRemainSeparate`
- `duplicateAwaiterForOneInvocationCannotReplaceTheOriginalContinuation`
- `cancellationByExecutionRemovesPendingRequestsAndGrants`
- `approvalExpiresWithInjectedClockAndCannotBeApprovedLate`
- `denialAndExecutionCancellationClearInjectedTimeoutSleepers`

### MiraCoreTests/MemoryContextTests.swift

- `prefetchSelectsAtMostSixWholeEntriesAndReferencesExactRevisions`
- `prefetchUsesEightPercentBudgetAndOmitsOversizedEntryWhole`
- `suppliedMemoriesAreRevalidatedForScopeStateTimeAndOutboundPolicy`
- `dynamicMemoryChangesPreserveSystemHistoryAndFrozenToolContinuation`
- `sourcePrefetchRendersBoundedUntrustedContextAndExactReferences`
- `sourcePrefetchRejectsWrongScopeStaleVersionAndLocalOnlyHits`
- `suppressedSourcesAndPurgedAssistantBodiesDoNotEnterHistoryButCurrentInputRemains`

### MiraCoreTests/MemoryDerivedHistoryTests.swift

- `forgottenFailedAttemptDoesNotBlockHistoryFromASuccessfulRetry`
- `forgettingMemoryRetainsCommittedHistoryAndExcludesItFromFutureRequests`

### MiraCoreTests/MemoryExtractionApplicationTests.swift

- `defaultManualOnlyReplyDoesNotStartExtraction`
- `enablingExtractionUsesDedicatedRouteAndCommitsSeparateAudit`
- `ordinaryRoutinePreferenceBecomesActiveAndIsRecalledWithoutMemoryInstruction`
- `disablingDuringSuspendedExtractionCancelsLateCommitAndPreservesForegroundWork`
- `forgettingWhileExtractionSuspendedBlocksLateCommitAndKeepsForegroundIndependent`

### MiraCoreTests/MemoryRememberApplicationTests.swift

- `directRememberCommitsLocalMemoryAndPairedReceiptBeforeFinalReply`
- `paraphrasedRememberRequiresHostDecisionAndDenialHasNoSuccessReceipt`
- `ordinaryRememberCallIsDeniedWhenAutomaticCaptureHandlesIt`

### MiraCoreTests/MemoryToolTests.swift

- `reusedMemoryReceiptReportsCommittedRemoteUsePolicyWithoutChangingIt`
- `directAnchoredRememberSavesOnceAfterDurableDispatchAndStaysLocal`
- `paraphrasedContentRequiresApprovalAndDoesNotWriteBeforeApproval`
- `globalScopeFromWorkspaceRequiresApprovalAndUsesGlobalScopeAfterApproval`
- `denialProducesNoMemoryAndNoFalseSuccessReceipt`
- `cancellationWhileApprovalIsPendingClearsApprovalAndDoesNotWrite`
- `suppressedSourceRetryRequiresASeparateApproval`
- `readOnlySearchAndGetRespectScopeAndRecordUsagesForForget`

### MiraCoreTests/MiraApplicationTests.swift

- `configurationMutationEmitsScopedConfigurationEvent`
- `startConversationPrevalidatesAndEmitsConversationIdentity`
- `startConversationRejectsRouteAndWorkspaceBeforeCreatingRows`
- `failedFinalizationRetainsReplyAndCanBeRetriedWithoutCallingModel`
- `shutdownRejectsNewRequestsAndEmptyModelOutputFails`
- `persistsRequestBeforeProviderAndRecoversLatestCheckpointOnCancellation`
- `retriesWithoutDuplicatingUserOrRetainingFailedAnswerInNextContext`
- `blocksIncompleteRouteBeforeCommitAndPrivateWorkspaceBeforeNetwork`
- `concurrentWindowSendsAreBoundedAndRouteMutationCancelsExecution`
- `staleProbeResultsCannotOverwriteChangedModelOrRouteConfiguration`
- `prematureEOFAndOutputLimitDoNotBecomeSuccessfulHistory`
- `thinkingOnlyCancellationKeepsDraftAndRetryDoesNotReplayIt`
- `pendingSaveRetainsThinkingWithoutRepeatingTheModelCall`

### MiraCoreTests/ModelConfigurationTestSupport.swift

仅旧协议测试夹具，无独立测试声明。

### MiraCoreTests/ModelConfigurationTests.swift

- `explicitConversationWorkspaceAndGlobalBindingsHaveOrderedPrecedence`
- `purposesResolveIndependentlyAtTheSameScope`
- `missingOrDanglingSelectionRejectsWithoutFallingBack`
- `workspaceMismatchAndConnectionPolicyAreEnforced`
- `unknownContextOrTextCapabilityBlocksSending`
- `whitespaceCredentialReferencesAreRejectedBeforeResolutionOrSending`
- `capabilityObservationFromAnOlderConnectionRevisionIsNotTrusted`
- `resolvedSnapshotKeepsImmutableFieldsAfterConfigurationChanges`
- `modelPoolShowsOnlyEnabledModelsWithCanonicalRoutesIncludingUnknownCapabilities`
- `disabledConnectionAndModelRejectExplicitResolutionWithoutFallback`
- `modelSelectionUsesKeepUnknownModelsForManagementButGateEachUse`
- `staleExtractionCapabilityIsClearedFromSnapshotsAndSelection`
- `catalogMetadataBoundsModelIDModalitiesAndOutputLimit`
- `thinkingSettingsRespectProtocolModelAndOutputBudget`

### MiraCoreTests/NaturalMemoryRecallTests.swift

- `genericMorningCueDoesNotExpandByItself`
- `sourcePrefetchGateRequiresBothCues`
- `ordinaryRelevantTaskReceivesPrefetchedMemoryWithoutMemorySearchRequest`
- `bilingualBreakfastParaphraseReceivesActiveMemory`
- `ordinaryUnrelatedTaskReceivesNoPrefetchedMemory`

### MiraCoreTests/ProviderActivationPersistenceTests.swift

- `textProbeCannotCertifyToolsOrExtraction`
- `probeUpdatesOnlyTheRequestedCapabilityAndRejectsStaleSnapshots`

### MiraCoreTests/ProviderCapabilityProbeTests.swift

- `unknownWindowFailsBeforeTransport`
- `textRequiresNonEmptyStopAndToolRequiresExactCall`
- `falsePositiveToolAndMissingTerminalFail`
- `probeUsesSyntheticInputAndTemporaryCapabilitiesWithoutChangingRoute`
- `malformedOrOversizedProbeStreamsCannotVerifyCapabilities`
- `cancellingProbeDoesNotReportFailedCapabilityAndEndsItsStream`
- `injectedDeadlineReportsTimeoutAndCancelsTransport`
- `jsonExtractionProbeRequiresExactJSONAndDoesNotDeclareTextOrTools`

### MiraCoreTests/ToolRuntimeTests.swift

- `interruptedFollowupDoesNotReusePreviousCallsUsage`
- `twoStepsKeepCompleteExchangeButNextTurnDoesNotReuseToolObservations`
- `invalidUnknownDeniedAndOversizedResultsArePairedInModelOrder`
- `parallelSafeBatchesRespectExclusiveBarriersAndReturnOriginalOrder`
- `cancellationProducesReceiptsForUnscheduledToolsWithoutRunningThem`
- `toolTimeoutUsesInjectedClockAndDoesNotClaimSuccess`
- `stepToolAndOutputReservationBudgetsStopBeforeExtraDispatch`
- `unknownCapabilityDoesNotExposeToolsAndMalformedPairingNeverExecutes`
- `policyTighteningDuringAuthorizationPreventsDispatch`
- `entireTurnDeadlineIsDistinctFromUserCancellation`
- `completeExchangeOverContextBudgetNeverDispatchesAnOrphanedRequest`
- `repeatedCallsWithIdenticalObservationsStopWithoutARepeatedNetworkRequest`
- `schemaRejectsUnknownKeysAndRegistryRejectsWireNameCollisions`
- `thinkingSurvivesToolContinuationAndUsesProviderHistoryBoundary`
- `incompleteThinkingNeverDispatchesTools`

### MiraDataTests/KnowledgeBackupTests.swift

- `bundleRoundTripPreservesMixedScopesAndHistoricalCitation`
- `restoreRejectsMissingBlobAndLeavesDestinationAbsent`
- `restoreRejectsBlobDigestTamperingAndPathSymlinks`
- `restoreRejectsMalformedManifest`
- `exportAndRestoreRefuseOverwritingExistingDirectories`
- `exportFaultsLeaveNoPartialBundle`
- `restoreFaultsLeaveSourceAndDestinationUntouched`

### MiraDataTests/KnowledgeStoreTests.swift

- `duplicateContentAndSameNamesHaveDistinctRules`
- `explicitUpdateKeepsHistoricalBytesAndFailedVersion`
- `globalWorkspaceAndRemotePermissionFilterBeforeResults`
- `multilingualCodeAndLiteralSearchWorkWithAndWithoutTrigrams`
- `shortChineseFallbackUsesChunkOrderAndCurrentScope`
- `importFaultsLeaveExistingCanonicalVersionsIntact`
- `garbageCollectionHonorsAllHistoricalAndSharedReferences`
- `shortQueryDisclosesBoundedCandidateScan`

### MiraDataTests/M5LibraryRoundTripTests.swift

- `canonicalBundleRoundTripPreservesScopesVersionsCitationsAndPrivacy`

### MiraDataTests/M5PerformanceTests.swift

- `benchmark`

### MiraDataTests/MemoryCitationStoreTests.swift

- `referencesRequireUsageAndResolveTheExactHistoricalRevision`
- `anotherExecutionCannotOpenAGuessedMemoryReference`

### MiraDataTests/MemoryExtractionCommitTests.swift

- `persistsExtendedUsageAndChargesInclusiveInput`
- `missingExclusiveCacheUsagePreservesPartialCountersAndChargesReservation`
- `rejectsInvalidUsageBeforeSettlingAttempt`
- `fractionalActivationAndReviewedMemorySurviveBackup`
- `successfulCommitHasEvidenceRevisionCaptureAndSingleSettlement`
- `malformedJSONSettlesUsageWithoutPartialMemories`
- `reportedUsageAboveReservationIsNeverClampedDown`
- `databaseFailureRollsBackEveryMemoryAndDecision`
- `explicitFactIsNeverAutomaticallyReplaced`
- `unrelatedSameKindAssertionsCanBothBecomeActive`
- `explicitNaturalChangeReplacesOnlyObservedCurrentAspect`
- `explicitUserReviewBlocksAutomaticNaturalReplacement`
- `assertionMetadataIsRevisionBoundAndPurgedWithMemory`
- `manualTopicConflictRequiresReviewButUnrelatedPreferenceStaysActive`
- `candidatePolicyAndSensitiveClassificationCannotAutoActivate`
- `disablingPolicyRejectsLateCommitAndChargesOnlyOnce`
- `rejectingFirstCaptureSuppressesLaterJobsForTheSameSource`

### MiraDataTests/MemoryExtractionPrivacyTests.swift

- `successfulExtractionBackupRestoresCommittedMemoryAndAudit`
- `revisedExtractionMemoryBackupRetainsHistoricalAssertionMetadataBinding`
- `restoreRejectsPurgedAssertionMetadataOnLiveMemory`
- `forgettingExtractionMemoryPurgesBodiesAndPreservesSourceAndAccounting`
- `restoreRejectsResurrectedAttemptBodyUnderPurgedExtractionJob`
- `restoreRejectsMismatchedDecisionOrMemoryEvidence`
- `restoreRejectsRunningExtractionWithoutMatchingLeaseOrAttemptOrdinal`
- `restoreRejectsImpossibleExtractionBudgetAccounting`
- `lateWorkerCannotCommitOrRetryAfterForget`

### MiraDataTests/MemoryExtractionStoreTests.swift

- `completedReplyDoesNotQueueWhileCaptureIsManualOnly`
- `capturePolicyStartsManualOnlyAndUsesCAS`
- `completedForegroundReplyQueuesOnlyAfterActivation`
- `preactivationSourceIsNeverBackfilledWhenItFinishesAfterOptIn`
- `claimPreparesDispatchesAndFailsWithLease`
- `foregroundActivityBlocksBackgroundClaim`
- `missingDedicatedRoutePausesThatJobAndClaimsLaterValidJob`
- `workspacePolicyRejectsExtractionClaim`
- `workspaceConnectionAllowlistRejectsMismatchedRoute`
- `startupRecoveryRequeuesUnsentClaimImmediately`
- `expiredUnsentLeaseReturnsToQueue`
- `expiredDispatchedLeasePausesAndChargesCeilingOnlyOnce`
- `forgedClaimSourceAndAttemptIdentityCannotPrepare`
- `exactExtractionRequestSchemaIsRequired`
- `restoringBackupDisablesExtractionWithoutMutatingOriginal`
- `exhaustedBudgetRejectsPreparationWithoutCharging`
- `preparedBeforeUTCMidnightCanDispatchAfterDayRollover`
- `retryUnderNewPolicyCreatesDistinctJobAndPreservesOldProvenance`

### MiraDataTests/MemoryHistoryStatusTests.swift

- `noticesReportUpdatedSupersededArchivedExpiredAndUnavailablePolicies`
- `noticesAreLimitedToExecutionsInTheRequestedConversation`

### MiraDataTests/MemoryPrivacyTests.swift

- `restoreRejectsCoherentRetainedEvidenceForForgottenMemory`
- `restoreRejectsCoherentRetainedRevisionDraftForForgottenMemory`
- `restoreRejectsRecreatedFTSBodyForForgottenMemory`
- `restoreRejectsMissingOrMismatchedForgottenSourceSuppression`
- `restoreRejectsRetainedAuditChildrenUnderPurgedExecution`
- `restoreAcceptsHistoricalMemoryUsageAfterMemoryRevision`

### MiraDataTests/MemoryStoreTests.swift

- `malformedContextDoesNotPersistAnAttempt`
- `manualMemoryRoundTripsAndRevisionUsesCAS`
- `operationReceiptsAreStableAcrossSetOrderingAndForgottenRowsDoNotResurrect`
- `committedUserEvidenceIsExactAndAssistantEvidenceIsRejected`
- `emptyRecallReturnsNoUnrelatedMemoriesAndForgetRedactsLinkedExecution`
- `recallUsesEntityIDAllowlistsTemporalPolicyAndPunctuationTokens`
- `recallUsesNativeCJKWordTokensAndKeepsRecallFiltersBeforeTheCap`
- `globalMemoryInheritsSourceWorkspaceOutboundPolicy`
- `sharedSourceSuppressionKeepsStrongestReasonAcrossMemoryStates`
- `replacementConfirmationRequiresSuccessorChainAndBothCASRevisions`

### MiraDataTests/SQLiteMiraStoreTests.swift

- `startConversationAtomicallyCreatesFirstTurn`
- `startConversationRollsBackConversationWhenFirstEnqueueFails`
- `emptyConversationTitleIsAcceptedAndReadAsUntitled`
- `firstUserInputMatchingGeneratedTitleDoesNotRenameOnSecondSend`
- `oldSchemaVersionIsRejectedWithoutChangingTheLibraryFile`
- `schema8IsRejectedWithoutChangingTheLibraryFile`
- `schema9IsRejectedWithoutChangingTheLibraryFile`
- `catalogAndProtocolFieldsRoundTripThroughSchema11TypedMirrors`
- `reasoningOnlyDraftRecoversAsInterruptedAssistantTrace`
- `completeReasoningTraceSurvivesBackupAndMalformedTraceIsRejected`
- `failedMigrationPreservesExistingRows`
- `modelConfigurationCRUDAndBindingCASRoundTrips`
- `activationOnlyConnectionEditsPreserveFreshAttestationsButEndpointEditsStaleThem`
- `unchangedConnectionSavePreservesCapabilitiesButKeyRotationDoesNot`
- `savePoolModelIsAtomicAndUsesIndependentModelAndRouteCAS`
- `disabledProviderAndModelRoundTripThroughBackup`
- `deletingConnectionCascadesConfigurationButPreservesExecutionSnapshotAndPolicy`
- `staleModelConnectionRevisionCannotBeSavedAfterConnectionChange`
- `routeBindingRequiresExistingScopeAndUsesStableScopePurposeID`
- `malformedConfigurationAndBindingJSONAreRejectedBeforeBackupInstall`
- `malformedHistoricalRouteSnapshotIsRejectedBeforeBackupInstall`
- `malformedWorkspaceConnectionAllowlistIsRejectedFromBackup`
- `independentConnectionsRaceWithoutCreatingTwoActiveExecutions`
- `restoreRejectsMissingInvariantIndexBeforeInstallation`
- `persistsConversationAndExecutionAcrossReopen`
- `recoveryMaterializesDraftOnceAndTerminalFinishIsIdempotent`
- `concurrentFinishCommitsOneAssistantMessage`
- `backupRestoresIntoUnusedDirectoryAndDiagnosticsProbeSQLite`
- `enqueueFailureRollsBackExecutionAndRevisionConflictsAreRejected`
- `retryMustTargetLatestExecutionForTheTrigger`
- `newerBackupIsRejectedWithoutChangingLiveStore`
- `unknownMigrationIsRejectedAndExistingParentModeIsPreserved`
- `malformedBackupRowsAreRejectedBeforeInstall`
- `malformedBusinessIDsSurfaceStorageErrorInsteadOfCrashing`
- `auditPersistsExactCallsAndBlocksNextStepUntilEveryResultExists`
- `incompleteModelReasoningIsRejectedBeforeToolAuditWrites`
- `invalidThinkingBudgetIsRejectedBeforeRouteCommit`
- `recoveryClosesAuditCallsExactlyOnceByDispatchState`
- `auditRejectsForeignAttemptAndTerminalizesOpenToolsOnFinish`
- `completedStopCannotRetrySameStepOrOpenAnotherStep`
