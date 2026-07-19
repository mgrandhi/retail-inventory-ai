import type {
  AiConfig,
  AiProviderId,
  AnalysisJob,
  InsightChartId,
  Insights,
  InsightSummary,
  ScanHistory,
} from './types'

const INSIGHT_CHART_IDS: InsightChartId[] = [
  'category_frequency',
  'shelf_composition',
  'products_by_scan',
  'empty_shelf_area',
  'subcategory_breakdown',
]

async function request<T>(path: string, options?: RequestInit): Promise<T> {
  const response = await fetch(path, options)
  const payload = await response.json().catch(() => ({}))
  if (!response.ok) {
    const detail = payload.detail
    const message = typeof detail === 'string'
      ? detail
      : Array.isArray(detail)
        ? detail.map((item) => item?.msg).filter(Boolean).join('. ')
        : ''
    throw new Error(message || 'Something went wrong. Please try again.')
  }
  return payload as T
}

export type AnalysisSettings = {
  maxCrops: number
  maxSkuCrops: number
  extractSku: boolean
  skuProvider: AiProviderId
  skuModel: string
}

export async function startAnalysis(file: File, settings: AnalysisSettings): Promise<string> {
  const form = new FormData()
  form.append('image', file)
  form.append('max_crops', String(settings.maxCrops))
  form.append('max_sku_crops', String(settings.maxSkuCrops))
  form.append('extract_sku', String(settings.extractSku))
  form.append('sku_provider', settings.skuProvider)
  form.append('sku_model', settings.skuModel)
  const payload = await request<{ job_id: string }>('/api/analyses', {
    method: 'POST',
    body: form,
  })
  return payload.job_id
}

export function getAnalysis(jobId: string) {
  return request<AnalysisJob>(`/api/analyses/${jobId}`)
}

export function getInsights(signal?: AbortSignal) {
  return request<Insights>('/api/insights', { signal })
}

export function getAiConfig(signal?: AbortSignal) {
  return request<AiConfig>('/api/ai-config', { signal })
}

export async function generateInsightSummary(
  provider: AiProviderId,
  model: string,
  signal?: AbortSignal,
) {
  const payload = await request<unknown>('/api/insight-summaries', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ provider, model }),
    signal,
  })
  return normalizeInsightSummary(payload)
}

export function getHistory() {
  return request<{ scans: ScanHistory[]; stats: Record<string, number> }>('/api/scans')
}

export function sendDetectionFeedback(payload: {
  scanId: number
  cropId: number
  feedbackType: 'category' | 'sku'
  verdict: 'correct' | 'incorrect'
  correction?: string
}) {
  return request<{ id: number; status: string; message: string }>('/api/feedback', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      scan_id: payload.scanId,
      crop_id: payload.cropId,
      feedback_type: payload.feedbackType,
      verdict: payload.verdict,
      correction: payload.correction || '',
    }),
  })
}

export function askInventory(question: string) {
  return request<{ text: string; source: string; table?: Record<string, unknown>[] }>(
    '/api/questions',
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ question }),
    },
  )
}

export function normalizeInsightSummary(payload: unknown): InsightSummary {
  if (!payload || typeof payload !== 'object') {
    throw new Error('The inventory summary response was invalid. Please generate it again.')
  }
  const raw = payload as Record<string, unknown>
  const overallSummary = typeof raw.overall_summary === 'string' ? raw.overall_summary.trim() : ''
  if (!overallSummary) {
    throw new Error('The inventory summary response was incomplete. Please generate it again.')
  }
  const rawCharts = raw.charts && typeof raw.charts === 'object'
    ? raw.charts as Record<string, unknown>
    : {}
  const charts: InsightSummary['charts'] = {}
  for (const chartId of INSIGHT_CHART_IDS) {
    const candidate = rawCharts[chartId]
    if (!candidate || typeof candidate !== 'object') continue
    const chart = candidate as Record<string, unknown>
    const chartSummary = typeof chart.summary === 'string' ? chart.summary.trim() : ''
    if (!chartSummary) continue
    const adminActions = Array.isArray(chart.admin_actions)
      ? chart.admin_actions.filter((action): action is string => typeof action === 'string' && Boolean(action.trim()))
      : []
    charts[chartId] = { summary: chartSummary, admin_actions: adminActions }
  }
  const normalizedProvider = raw.provider === 'gemini' || raw.provider === 'openrouter'
    ? raw.provider
    : null
  const normalizedModel = typeof raw.model === 'string' ? raw.model : null
  return {
    overall_summary: overallSummary,
    charts,
    source: raw.source === 'llm' && normalizedProvider && normalizedModel ? 'llm' : 'deterministic',
    provider: normalizedProvider,
    model: normalizedModel,
    warning: typeof raw.warning === 'string' ? raw.warning : '',
  }
}
