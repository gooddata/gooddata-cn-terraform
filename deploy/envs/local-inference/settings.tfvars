###
# AWS
###
aws_profile_name = "aws-panther-dev"
aws_region       = "us-east-1"
deployment_name  = "local-inference"

###
# GoodData CN
###
helm_gdcn_version = "4.7.0"
gdcn_license_key  = "" # set via GDCN_LICENSE_KEY secret in CI, or fill in locally

size_profile       = "dev"
enable_ai_features = true

# Cost guardrail: the module default is 20 nodes max — a runaway workload
# could autoscale to ~$100+/day. 6 small dev nodes is plenty for CN + AI.
eks_max_nodes = 6

###
# Inference strategy: everything runs IN OUR CLUSTER — open-weights model
# (Qwen3.6-27B from Hugging Face) served by vLLM on our GPU pool. Nothing
# flows through Superlinked. See deploy/k8s/vllm-qwen.yaml.
# GPU scales from zero: cost accrues only while an inference pod runs.
###
enable_inference_gpu_pool   = true
inference_gpu_instance_type = "g6e.xlarge" # 1x L40S 48GB ~$1.86/h — fits 27B in FP8
inference_gpu_max_nodes     = 1

###
# DNS
###
dns_provider    = "route53"
route53_zone_id = "Z0163735X341CJ9LRA4X"

###
# Ingress + TLS
###
ingress_controller = "alb"
tls_mode           = "acm"

###
# Organization
###
auth_hostname = "auth.local-inference.dev11.devgdc.com"

gdcn_orgs = [
  {
    id          = "main"
    name        = "Main"
    admin_user  = "admin"
    admin_group = "adminGroup"
    hostname    = "gooddata.local-inference.dev11.devgdc.com"
  }
]

###
# Feature flags — set to true/false to toggle. Flags marked (ai) are already
# enabled by enable_ai_features=true above; keep them true or they'll be overridden.
###
gdcn_helm_extra_values = <<-EOT
  # --- Analytics & Visualization ---
  enableSortingByTotalGroup: false
  ADmeasureValueFilterNullAsZeroOption: false
  enableMultipleDates: false
  enableKPIDashboardDeleteFilterButton: false
  dashboardEditModeDevRollout: false
  enableMetricSqlAndDataExplain: false
  enableMetricFormatOverrides: false
  enableImplicitDrillToUrl: false
  enableKPIDashboardExportPDF: false
  enableExtendedFiltering: false
  enableCompositeGrain: false
  enableSmartFunctions: false
  enableExperimentalFeaturesUI: false
  enableScatterPlotClustering: false
  enableRichTextDescriptions: false
  enableWorkspacesHierarchyView: false
  enableFlexibleDashboardLayout: false
  enableDashboardAfterRenderDetection: false
  enableLineChartTrendThreshold: false
  enableToDateFilters: false
  enableCyclicalToDateFilters: false
  enableInsideJoinFilters: false
  enableUseDateFilters: false
  enableNewPivotTable: false
  enableLowerFilterGranularity: false
  enableGeoArea: false
  enableNewGeoPushpin: false
  enableGeoBasemapConfig: false
  enableGeoSatelliteBasemapOption: false
  enableGeoPushpinIcon: false
  enableFiscalCalendars: false
  enableMetriclessViaNumeric: false
  enableMetriclessViaBothWitnesses: false
  enableNullJoins: false
  enableParameters: false
  enableHLL: false
  enableImprovedAdFilters: false
  enableMultipleMvfConditions: false
  enableMatchFilterAD: false
  enableArbitraryFilterAD: false
  enableMatchFilterKD: false
  enableArbitraryFilterKD: false
  enableMeasureValueFilterKD: false
  enableDashboardFilterGroups: false
  enableEmptyDateValuesFilter: false
  enableKDEmptyDateValuesFilter: false
  enableFilterControlInDrillingConfiguration: false
  enableCustomGeoCollection: false
  enableRankingWithMvf: false
  enableCustomizableCsvDelimiter: false
  enableKDSavedFilters: false
  enableKDCrossFiltering: false

  # --- Data Sources ---
  enableMySqlDataSource: false
  enableMariaDbDataSource: false
  enableSingleStoreDataSource: false
  enableOracleDataSource: false
  enableMotherDuckDataSource: false
  enableAthenaDataSource: false
  enableMongoDbDataSource: false
  enablePinotDataSource: false
  enableSnowflakeKeyPairAuthentication: false
  enableScanTypeByDatabaseType: false
  enableStarrocksDataSource: false
  enableCrateDbDataSource: false
  enableDataSourceRouting: false
  enablePreAggregationDatasets: false
  enableModernQuiverKeyspace: false

  # --- Exports ---
  enableDashboardTabularExport: false
  enableRawExports: false
  enableChunkedRawExports: false
  enableDefaultTabularExportLabelOverrides: false
  enableExportToDocumentStorage: false
  enableOptimizedXlsxExports: false
  enableNewPdfTabularExport: false
  enableNewExportFlow: false
  enableSnapshotExportAccessibility: false
  enableDashboardShareLink: false
  enableDashboardShareDialogLink: false

  # --- Scheduling & Alerting ---
  enableScheduling: false
  enableAlerting: false
  enableSmtp: false
  enableDefaultSmtp: false
  enableInPlatformNotifications: false
  enableExternalRecipients: false
  enableNewScheduledExport: false
  enableAutomationManagement: false
  enableNotificationSource: false
  enableAutomationExportRetries: false
  enableAutomationRunPersistence: false

  # --- User & Access Management ---
  enableUserManagement: false
  enableDataLocalization: false
  enableColumnLevelPermissions: false
  enableSystemAccountFiltering: false
  enableUdfCountContext: false
  enableSpiceDBLive: false

  # --- AI features (already on via enable_ai_features=true) ---
  enableSemanticSearch: true
  enableGenAIChat: true
  enableAiAgenticConversations: true
  enableGenAIMemory: true
  enableSemanticSearchInChat: true
  enableAIKnowledge: true
  enableAiHub: true
  enableAiAgenticMultiConversations: false
  enableGenAIAlerts: false
  enableGenAIPromptRedesign: false
  enableGenAiMetricSkill: false
  enableGenAICatalogQualityChecker: false
  enableGenAiAiModuleGating: false
  aiMeteringEnforcement: false
  enableA2AServer: false
  enableGenAiAgentSwitching: false
  enableScheduledExportSkill: false
  enableMultilingualAIAssistant: false
  enableGenAIReasoningVisibility: true
  enableGenAiAttributeValues: false
  enableAnomalyDetectionVisualization: false
  enableAnomalyDetectionAlert: false
  enableAIDataSetting: false
  enableGenAiMemoryAgent: false
  enableGenAiKdaSkill: false
  enableGenAiWhatifSkill: false
  enableGenAiForecastingSkill: false
  enableGenAiAnomalySkill: false
  enableGenAiClusteringSkill: false
  enableGenAiVisualizationSummarySkill: true
  enableGenAiDashboardSummarySkill: true
  enableGenAiHeadlessSummary: false
  enableGenAiAlertSkill: false
  enableGenAiVisualizationSkill: true
  enableGenAiRankingFilter: false
  enableKeyDriverAnalysis: false
  enableLabsSmartFunctions: false
  enableChangeAnalysis: false

  # --- Catalog & Search ---
  enableAnalyticalCatalog: false
  enableDataProfiling: false
  enableCatalogSmartSearchResults: false
  enableWorkspaceCacheInvalidation: false

  # --- Gateway & Auth ---
  enableGatewayOauth: false
  enableGatewayApiTokens: false
  enableGatewayJwt: false
  enableSeamlessIdpSwitch: false

  # --- Shell applications ---
  enableShellApplication: false
  enableShellApplication_metricEditor: false
  enableShellApplication_ldmModeler: false
  enableShellApplication_analyticalDesigner: false
  enableShellApplication_dashboards: false
  enableShellApplication_catalog: false

  # --- Misc ---
  enableDeploymentInfo: false
  enableCertification: false
  enablePlaywrightEvaluate: false

  # --- Custom gen-ai image override ---
  # Built from gdc-nas branch jan/local-inference (LOCAL provider +
  # ChatCompletionsLlmAdapter for OpenAI-compatible servers: SIE/vLLM/TGI).
  # Uncomment AFTER the image is pushed to ECR (CI build-and-push job, or
  # docker buildx --platform linux/amd64 + push), then re-run apply (~2 min).
  services:
    genAi:
      image:
        repositoryPrefix: "020413372491.dkr.ecr.us-east-1.amazonaws.com/dev"
        name: "mark43-ai"
        tag: "jan-local-inference"
EOT
