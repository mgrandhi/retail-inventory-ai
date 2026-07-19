import { useEffect, useRef, useState, type ChangeEvent, type DragEvent } from 'react'
import {
  AlertTriangle,
  ArrowRight,
  BarChart3,
  Camera,
  Check,
  ChevronRight,
  Clock3,
  Download,
  History,
  ImagePlus,
  ListFilter,
  MessageCircleQuestion,
  PackageCheck,
  RefreshCw,
  ScanLine,
  Search,
  MessageSquareCheck,
  SlidersHorizontal,
  Sparkles,
  ThumbsDown,
  ThumbsUp,
  Upload,
} from 'lucide-react'
import { BrowserRouter, Link, Navigate, NavLink, Route, Routes } from 'react-router-dom'
import {
  Bar,
  BarChart,
  Cell,
  CartesianGrid,
  Line,
  LineChart,
  Pie,
  PieChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts'
import {
  askInventory,
  generateInsightSummary,
  getAiConfig,
  getAnalysis,
  getHistory,
  getInsights,
  sendDetectionFeedback,
  startAnalysis,
} from './api'
import type {
  AiConfig,
  AiProviderId,
  AnalysisJob,
  Detection,
  Insights,
  InsightChartId,
  InsightSummary,
  ScanHistory,
  ScanResult,
} from './types'
import './App.css'

const sleep = (milliseconds: number) => new Promise((resolve) => setTimeout(resolve, milliseconds))

function Shell() {
  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="brand">
          <span className="brand-mark"><ScanLine aria-hidden="true" /></span>
          <span><strong>ShelfSight</strong><small>Retail assistant</small></span>
        </div>
        <nav aria-label="Main navigation">
          <NavLink to="/insights"><BarChart3 /><span>Insights</span></NavLink>
          <NavLink to="/scan"><Camera /><span>Scan shelf</span></NavLink>
          <NavLink to="/history"><History /><span>History</span></NavLink>
          <NavLink to="/ask"><MessageCircleQuestion /><span>Ask inventory</span></NavLink>
        </nav>
        <div className="sidebar-note">
          <span className="status-dot" />
          <div><strong>AI service connected</strong><small>Ready for shelf photos</small></div>
        </div>
      </aside>
      <main>
        <header className="topbar">
          <div className="mobile-brand"><ScanLine /> ShelfSight</div>
        </header>
        <div className="page-wrap">
          <Routes>
            <Route path="/" element={<Navigate replace to="/insights" />} />
            <Route path="/scan" element={<ScanPage />} />
            <Route path="/insights" element={<InsightsPage />} />
            <Route path="/history" element={<HistoryPage />} />
            <Route path="/ask" element={<AskPage />} />
          </Routes>
        </div>
      </main>
    </div>
  )
}

function PageHeading({ eyebrow, title, copy }: { eyebrow: string; title: string; copy: string }) {
  return (
    <div className="page-heading">
      <span className="eyebrow">{eyebrow}</span>
      <h1>{title}</h1>
      <p>{copy}</p>
    </div>
  )
}

function ScanPage() {
  const [file, setFile] = useState<File | null>(null)
  const [preview, setPreview] = useState('')
  const [job, setJob] = useState<AnalysisJob | null>(null)
  const [result, setResult] = useState<ScanResult | null>(null)
  const [resultOriginal, setResultOriginal] = useState('')
  const [error, setError] = useState('')
  const [dragging, setDragging] = useState(false)
  const [maxCrops, setMaxCrops] = useState(60)
  const [maxSkuCrops, setMaxSkuCrops] = useState(5)
  const [extractSku, setExtractSku] = useState(true)
  const [aiConfig, setAiConfig] = useState<AiConfig | null>(null)
  const [skuProvider, setSkuProvider] = useState<AiProviderId>('gemini')
  const [skuModel, setSkuModel] = useState('gemini-2.5-flash')
  const inputRef = useRef<HTMLInputElement>(null)
  const selectedSkuProvider = aiConfig?.providers.find((provider) => provider.id === skuProvider)

  useEffect(() => {
    getAiConfig().then((config) => {
      setAiConfig(config)
      const provider = config.providers.find((item) => item.id === config.default_provider)
      if (provider) {
        setSkuProvider(provider.id)
        setSkuModel(provider.default_model)
      }
    }).catch(() => setError('AI provider options could not be loaded. Refresh the page to retry.'))
  }, [])

  useEffect(() => {
    if (!file) {
      setPreview('')
      return
    }
    const url = URL.createObjectURL(file)
    setPreview(url)
    return () => URL.revokeObjectURL(url)
  }, [file])

  const chooseFile = (candidate?: File) => {
    setError('')
    if (!candidate) return
    if (!candidate.type.startsWith('image/')) {
      setError('Choose a JPG, PNG, BMP, or WebP shelf photo.')
      return
    }
    if (candidate.size > 15 * 1024 * 1024) {
      setError('That photo is over 15 MB. Choose a smaller image.')
      return
    }
    setFile(candidate)
    setJob(null)
  }

  const onDrop = (event: DragEvent<HTMLDivElement>) => {
    event.preventDefault()
    setDragging(false)
    chooseFile(event.dataTransfer.files[0])
  }

  const analyze = async () => {
    if (!file) return
    setError('')
    setJob({ job_id: '', status: 'queued', stage: 'uploading', progress: 1, message: 'Uploading your shelf photo' })
    try {
      const originalImage = await fileToDataUrl(file)
      const jobId = await startAnalysis(file, {
        maxCrops,
        maxSkuCrops,
        extractSku,
        skuProvider,
        skuModel,
      })
      for (;;) {
        const next = await getAnalysis(jobId)
        setJob(next)
        if (next.status === 'complete' && next.result) {
          setResult(next.result)
          setResultOriginal(originalImage)
          setJob(null)
          break
        }
        if (next.status === 'failed') throw new Error(next.error || next.message)
        await sleep(900)
      }
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : 'We could not analyze this image.')
      setJob(null)
    }
  }

  return (
    <>
      <PageHeading
        eyebrow="New shelf check"
        title="Turn a shelf photo into clear next steps"
        copy="Upload one clear photo. We’ll find each product, identify what we can, and highlight anything worth a second look."
      />
      <div className="scan-layout">
        <section className="card upload-card" aria-labelledby="upload-title">
          <div className="section-title">
            <span className="step-badge">1</span>
            <div><h2 id="upload-title">Add a shelf photo</h2><p>Front-facing photos with even lighting work best.</p></div>
          </div>
          <input
            ref={inputRef}
            className="visually-hidden"
            type="file"
            accept="image/jpeg,image/png,image/bmp,image/webp"
            capture="environment"
            onChange={(event: ChangeEvent<HTMLInputElement>) => chooseFile(event.target.files?.[0])}
          />
          {preview ? (
            <div className="photo-preview">
              <img src={preview} alt="Shelf selected for analysis" />
              <button className="secondary floating" onClick={() => inputRef.current?.click()}>
                <RefreshCw /> Replace photo
              </button>
            </div>
          ) : (
            <div
              className={`drop-zone ${dragging ? 'dragging' : ''}`}
              onDragOver={(event) => { event.preventDefault(); setDragging(true) }}
              onDragLeave={() => setDragging(false)}
              onDrop={onDrop}
            >
              <span className="upload-icon"><ImagePlus /></span>
              <h3>Drop your shelf photo here</h3>
              <p>or choose a photo from this device</p>
              <button className="primary" onClick={() => inputRef.current?.click()}><Upload /> Choose photo</button>
              <span className="file-help">JPG, PNG, BMP or WebP · up to 15 MB</span>
            </div>
          )}
          <div className="capture-tips">
            <span><Check /> Keep the full shelf in frame</span>
            <span><Check /> Hold the camera straight</span>
            <span><Check /> Avoid glare and blur</span>
          </div>
          <details className="analysis-settings">
            <summary><span><SlidersHorizontal /> Analysis settings</span><small>Adjust speed and detail</small></summary>
            <div className="settings-body">
              <label className="setting-row">
                <span><strong>Products to categorize</strong><small>Limit how many detected products use the category library.</small></span>
                <output>{maxCrops === 0 ? 'All' : maxCrops}</output>
                <input type="range" min="0" max="300" step="10" value={maxCrops} onChange={(event) => setMaxCrops(Number(event.target.value))} />
              </label>
              <label className="toggle-row">
                <span><strong>Read SKU and package text</strong><small>Uses the vision model after category matching.</small></span>
                <input type="checkbox" checked={extractSku} onChange={(event) => setExtractSku(event.target.checked)} />
              </label>
              <label className={`setting-row select-setting ${!extractSku ? 'disabled' : ''}`}>
                <span><strong>OCR provider</strong><small>Credentials stay on the server and are never sent to this browser.</small></span>
                <select
                  aria-label="OCR provider"
                  value={skuProvider}
                  disabled={!extractSku || !aiConfig}
                  onChange={(event) => {
                    const provider = event.target.value as AiProviderId
                    const selected = aiConfig?.providers.find((item) => item.id === provider)
                    setSkuProvider(provider)
                    if (selected) setSkuModel(selected.default_model)
                  }}
                >
                  {aiConfig?.providers.map((provider) => (
                    <option value={provider.id} key={provider.id}>
                      {provider.label}{provider.available ? '' : ' (unavailable)'}
                    </option>
                  ))}
                </select>
              </label>
              <label className={`setting-row select-setting ${!extractSku ? 'disabled' : ''}`}>
                <span><strong>OCR model</strong><small>Choose from the models allowed by the server.</small></span>
                <select
                  aria-label="OCR model"
                  value={skuModel}
                  disabled={!extractSku || !aiConfig}
                  onChange={(event) => setSkuModel(event.target.value)}
                >
                  {aiConfig?.providers.find((provider) => provider.id === skuProvider)?.models.map((model) => (
                    <option value={model} key={model}>{model}</option>
                  ))}
                </select>
              </label>
              {aiConfig && !aiConfig.providers.find((provider) => provider.id === skuProvider)?.available && (
                <p className="provider-warning" role="status">
                  {aiConfig.providers.find((provider) => provider.id === skuProvider)?.unavailable_reason}
                </p>
              )}
              <label className={`setting-row ${!extractSku ? 'disabled' : ''}`}>
                <span><strong>Products to read for SKU</strong><small>Each product is a separate vision request. Lower is faster.</small></span>
                <output>{maxSkuCrops === 0 ? 'All' : maxSkuCrops}</output>
                <input type="range" min="0" max="100" step="1" value={maxSkuCrops} disabled={!extractSku} onChange={(event) => setMaxSkuCrops(Number(event.target.value))} />
              </label>
              <p className="settings-note">Choose “All” by moving a slider to 0. Large scans can take several minutes.</p>
            </div>
          </details>
          {error && <div className="alert error" role="alert"><AlertTriangle /> {error}</div>}
          <button
            className="primary analyze-button"
            disabled={!file || !!job || (extractSku && (!aiConfig || !selectedSkuProvider?.available))}
            onClick={analyze}
          >
            {job ? <><RefreshCw className="spin" /> Analyzing shelf…</> : <><Sparkles /> Analyze shelf <ArrowRight /></>}
          </button>
        </section>
        <aside className="card how-card">
          <span className="soft-icon"><ScanLine /></span>
          <h2>What happens next?</h2>
          <ol>
            <li><span>1</span><div><strong>Products are located</strong><small>Each visible item is outlined.</small></div></li>
            <li><span>2</span><div><strong>Categories are matched</strong><small>The product library finds the closest match.</small></div></li>
            <li><span>3</span><div><strong>Details are read</strong><small>Labels and package text are captured when clear.</small></div></li>
          </ol>
          <div className="privacy-note">Your scan is saved to inventory history for comparison.</div>
        </aside>
      </div>
      {job && <Processing job={job} />}
      {result && <Results result={result} originalImage={resultOriginal} />}
    </>
  )
}

function Processing({ job }: { job: AnalysisJob }) {
  const stages = ['detecting', 'identifying', 'reading', 'saving']
  const activeIndex = Math.max(0, stages.indexOf(job.stage))
  return (
    <section className="card processing-card" aria-live="polite">
      <div className="processing-head">
        <div><span className="eyebrow">Analysis in progress</span><h2>{job.message}</h2></div>
        <strong>{job.progress}%</strong>
      </div>
      <div className="progress-track"><span style={{ width: `${job.progress}%` }} /></div>
      <div className="stage-list">
        {['Find products', 'Match categories', 'Read packaging', 'Build report'].map((label, index) => (
          <span className={index <= activeIndex ? 'active' : ''} key={label}>
            {index < activeIndex ? <Check /> : <i>{index + 1}</i>}{label}
          </span>
        ))}
      </div>
      <p>You can leave this page open while the product library works in the background.</p>
    </section>
  )
}

function Metric({ label, value, note, tone = '' }: { label: string; value: string | number; note: string; tone?: string }) {
  return <div className={`metric ${tone}`}><span>{label}</span><strong>{value}</strong><small>{note}</small></div>
}

function Results({ result, originalImage }: { result: ScanResult; originalImage: string }) {
  const [annotated, setAnnotated] = useState(true)
  const [query, setQuery] = useState('')
  const [reviewOnly, setReviewOnly] = useState(false)
  const reviewItems = result.detections.filter(needsReview)
  const visible = result.detections.filter((item) => {
    const haystack = `${item.category} ${item.subcategory} ${item.brand} ${item.product_name} ${item.sku_text}`.toLowerCase()
    return haystack.includes(query.toLowerCase()) && (!reviewOnly || needsReview(item))
  })

  const downloadCsv = () => {
    const columns = ['crop_id', 'category', 'subcategory', 'brand', 'product_name', 'sku_text', 'package_size', 'barcode', 'sku_confidence']
    const csv = [
      columns.join(','),
      ...result.detections.map((row) => columns.map((key) => csvCell(row[key as keyof Detection])).join(',')),
    ].join('\n')
    const url = URL.createObjectURL(new Blob([csv], { type: 'text/csv' }))
    const anchor = document.createElement('a')
    anchor.href = url
    anchor.download = `shelf-scan-${result.scan_id}.csv`
    anchor.click()
    URL.revokeObjectURL(url)
  }

  return (
    <section className="results-section">
      <div className="result-heading">
        <div><span className="success-pill"><Check /> Scan complete</span><h2>Your shelf report is ready</h2><p>Scan #{result.scan_id} · {result.image_name}</p></div>
        <button className="secondary" onClick={downloadCsv}><Download /> Download report</button>
      </div>
      {result.warning && <div className="alert warning"><AlertTriangle /> {result.warning}</div>}
      <div className="metrics-grid">
        <Metric label="Products found" value={result.summary.num_items} note="Visible shelf items" />
        <Metric label="Categories" value={result.summary.distinct_categories} note={result.summary.shelf_type} />
        <Metric label="Possible shelf gap" value={`${Math.round(result.summary.empty_pct * 100)}%`} note={`${result.summary.empty_label} uncovered area`} tone={result.summary.empty_pct >= .55 ? 'warn' : ''} />
        <Metric label="Needs a look" value={reviewItems.length} note="Unclear or unmatched" tone={reviewItems.length ? 'warn' : 'good'} />
      </div>
      <div className="result-grid">
        <div className="card viewer-card">
          <div className="viewer-toolbar">
            <h3>Shelf view</h3>
            <div className="segmented" aria-label="Shelf image view">
              <button className={!annotated ? 'active' : ''} onClick={() => setAnnotated(false)}>Original</button>
              <button className={annotated ? 'active' : ''} onClick={() => setAnnotated(true)}>Identified</button>
            </div>
          </div>
          <img src={annotated ? result.annotated_image : originalImage} alt={annotated ? 'Shelf with identified products outlined' : 'Original shelf'} />
          <div className="legend"><span><i className="known" /> Identified</span><span><i className="unknown" /> Needs review</span></div>
        </div>
        <div className="card attention-card">
          <div className="section-title compact"><span className="soft-icon amber"><AlertTriangle /></span><div><h3>What needs attention</h3><p>Start with these items.</p></div></div>
          {reviewItems.length ? reviewItems.slice(0, 6).map((item) => (
            <div className="attention-row" key={item.crop_id}>
              <span>#{item.crop_id}</span>
              <div><strong>{displayName(item)}</strong><small>{attentionReason(item)}</small></div>
              <ChevronRight />
            </div>
          )) : <div className="all-clear"><PackageCheck /><strong>Everything looks clear</strong><p>No products need manual review.</p></div>}
          {result.summary.empty_pct >= .25 && (
            <div className="gap-note"><AlertTriangle /><span><strong>Possible open shelf area</strong><small>Review the {Math.round(result.summary.empty_pct * 100)}% uncovered area in the photo.</small></span></div>
          )}
        </div>
      </div>
      <div className="card inventory-card">
        <div className="inventory-head">
          <div><h3>Products in this scan</h3><p>{visible.length} of {result.detections.length} products shown</p></div>
          <div className="filters">
            <label><Search /><span className="visually-hidden">Search products</span><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search products" /></label>
            <button className={reviewOnly ? 'filter active' : 'filter'} onClick={() => setReviewOnly(!reviewOnly)}><ListFilter /> Needs review</button>
          </div>
        </div>
        <div className="product-list" role="list" aria-label="Detected products">
          {visible.map((item) => <ProductFeedbackRow item={item} scanId={result.scan_id} key={item.crop_id} />)}
          {!visible.length && <div className="empty-list">No products match these filters.</div>}
        </div>
      </div>
    </section>
  )
}

function ProductFeedbackRow({ item, scanId }: { item: Detection; scanId: number }) {
  const [open, setOpen] = useState(false)
  return (
    <div className="product-entry" role="listitem">
      <div className="product-row">
        <span className={`product-number ${needsReview(item) ? 'review' : ''}`}>{item.crop_id}</span>
        <div className="product-main"><strong>{displayName(item)}</strong><small>{item.subcategory !== 'unknown' ? item.subcategory : 'No subcategory'}{item.package_size ? ` · ${item.package_size}` : ''}</small></div>
        <span className="category-pill">{item.category === 'unknown' ? 'Unidentified' : item.category}</span>
        <div className="product-sku"><small>SKU / visible text</small><strong>{item.sku_text || item.visible_text || 'Not readable'}</strong></div>
        <span className={needsReview(item) ? 'review-label' : 'clear-label'}>{needsReview(item) ? 'Review' : 'Clear'}</span>
        <button className={`feedback-toggle ${open ? 'active' : ''}`} onClick={() => setOpen(!open)} aria-expanded={open}>
          <MessageSquareCheck /> Review AI
        </button>
      </div>
      {open && (
        <div className="feedback-panel">
          <FeedbackControl
            title="Category detection"
            prediction={item.category === 'unknown' ? 'No category detected' : `${item.category}${item.subcategory !== 'unknown' ? ` · ${item.subcategory}` : ''}`}
            correctionLabel="Correct category or subcategory (optional)"
            scanId={scanId}
            cropId={item.crop_id}
            feedbackType="category"
          />
          <FeedbackControl
            title="SKU / package reading"
            prediction={item.sku_text || item.visible_text || item.product_name || 'No SKU text detected'}
            correctionLabel="Correct SKU or package text (optional)"
            scanId={scanId}
            cropId={item.crop_id}
            feedbackType="sku"
          />
          <p className="feedback-disclaimer">Saved for model evaluation and future retraining. This does not change the current result.</p>
        </div>
      )}
    </div>
  )
}

function FeedbackControl({
  title,
  prediction,
  correctionLabel,
  scanId,
  cropId,
  feedbackType,
}: {
  title: string
  prediction: string
  correctionLabel: string
  scanId: number
  cropId: number
  feedbackType: 'category' | 'sku'
}) {
  const [verdict, setVerdict] = useState<'correct' | 'incorrect' | ''>('')
  const [correction, setCorrection] = useState('')
  const [status, setStatus] = useState<'idle' | 'saving' | 'saved' | 'error'>('idle')

  const submit = async (nextVerdict: 'correct' | 'incorrect') => {
    setVerdict(nextVerdict)
    setStatus('saving')
    try {
      await sendDetectionFeedback({
        scanId,
        cropId,
        feedbackType,
        verdict: nextVerdict,
        correction: nextVerdict === 'incorrect' ? correction : '',
      })
      setStatus('saved')
    } catch {
      setStatus('error')
    }
  }

  return (
    <div className="feedback-control">
      <div><strong>{title}</strong><small>AI result: {prediction}</small></div>
      <div className="verdict-buttons">
        <button className={verdict === 'correct' ? 'selected correct' : ''} disabled={status === 'saving'} onClick={() => submit('correct')}><ThumbsUp /> Correct</button>
        <button className={verdict === 'incorrect' ? 'selected incorrect' : ''} disabled={status === 'saving'} onClick={() => { setVerdict('incorrect'); setStatus('idle') }}><ThumbsDown /> Wrong</button>
      </div>
      {verdict === 'incorrect' && (
        <div className="correction-row">
          <input value={correction} maxLength={500} onChange={(event) => setCorrection(event.target.value)} placeholder={correctionLabel} aria-label={correctionLabel} />
          <button disabled={status === 'saving'} onClick={() => submit('incorrect')}>{status === 'saving' ? 'Saving…' : 'Save feedback'}</button>
        </div>
      )}
      {verdict === 'incorrect' && status === 'idle' && <span className="feedback-pending">Save to submit this correction</span>}
      {status === 'saved' && <span className="feedback-saved"><Check /> Feedback saved</span>}
      {status === 'error' && <span className="feedback-error">Could not save. Please try again.</span>}
    </div>
  )
}

function needsReview(item: Detection) {
  return item.category === 'unknown' || item.sku_needs_review === 1
}

function displayName(item: Detection) {
  return item.product_name || item.brand || (item.category === 'unknown' ? `Product ${item.crop_id}` : item.category)
}

function attentionReason(item: Detection) {
  if (item.category === 'unknown') return 'Category could not be matched'
  if (item.sku_error && item.sku_error !== 'not_processed_limit') return 'Package details could not be read'
  return 'Package text may need confirmation'
}

function csvCell(value: unknown) {
  const text = value == null ? '' : String(value)
  const safeText = /^[=+\-@\t\r]/.test(text) ? `'${text}` : text
  return `"${safeText.replaceAll('"', '""')}"`
}

function fileToDataUrl(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(String(reader.result || ''))
    reader.onerror = () => reject(new Error('We could not read this image. Please choose it again.'))
    reader.readAsDataURL(file)
  })
}

function isAbortError(reason: unknown) {
  return reason instanceof Error && reason.name === 'AbortError'
}

function InsightsPage() {
  const [data, setData] = useState<Insights | null>(null)
  const [aiConfig, setAiConfig] = useState<AiConfig | null>(null)
  const [provider, setProvider] = useState<AiProviderId>('gemini')
  const [model, setModel] = useState('gemini-2.5-flash')
  const [summary, setSummary] = useState<InsightSummary | null>(null)
  const [summaryLoading, setSummaryLoading] = useState(false)
  const [error, setError] = useState('')
  const [summaryError, setSummaryError] = useState('')
  const summaryRequestRef = useRef<{ id: number; controller: AbortController } | null>(null)

  const refreshSummary = async (nextProvider = provider, nextModel = model) => {
    summaryRequestRef.current?.controller.abort()
    const request = {
      id: (summaryRequestRef.current?.id || 0) + 1,
      controller: new AbortController(),
    }
    summaryRequestRef.current = request
    setSummaryLoading(true)
    setSummaryError('')
    try {
      const nextSummary = await generateInsightSummary(
        nextProvider,
        nextModel,
        request.controller.signal,
      )
      if (summaryRequestRef.current?.id === request.id) setSummary(nextSummary)
    } catch (reason) {
      if (!isAbortError(reason) && summaryRequestRef.current?.id === request.id) {
        setSummaryError(reason instanceof Error ? reason.message : 'Could not generate inventory summary.')
      }
    } finally {
      if (summaryRequestRef.current?.id === request.id) setSummaryLoading(false)
    }
  }

  useEffect(() => {
    const controller = new AbortController()
    let active = true
    setError('')
    getInsights(controller.signal)
      .then((insights) => {
        if (active) setData(insights)
      })
      .catch((reason) => {
        if (active && !isAbortError(reason)) {
          setError(reason instanceof Error ? reason.message : 'Could not refresh inventory insights.')
        }
      })
    getAiConfig(controller.signal)
      .then((config) => {
        if (!active) return
        setAiConfig(config)
        const selected = config.providers.find((item) => item.id === config.default_provider)
        if (selected) {
          setProvider(selected.id)
          setModel(selected.default_model)
          void refreshSummary(selected.id, selected.default_model)
        }
      })
      .catch((reason) => {
        if (active && !isAbortError(reason)) {
          setSummaryError(reason instanceof Error ? reason.message : 'AI options are unavailable.')
        }
      })
    return () => {
      active = false
      controller.abort()
      const summaryRequest = summaryRequestRef.current
      summaryRequestRef.current = null
      summaryRequest?.controller.abort()
    }
  }, [])

  const scanTrend = data?.scans.map((scan) => ({
    scan: `#${scan.id}`,
    products: scan.num_items,
    empty: Math.round(scan.empty_pct * 100),
  })) || []
  const selectedProvider = aiConfig?.providers.find((item) => item.id === provider)
  const pieColors = ['#176b55', '#4b9c7f', '#8bc7ad', '#d3a044', '#6f7d77', '#b7d7c8', '#d47c50', '#86a69a']
  return (
    <>
      <div className="insights-heading-row">
        <PageHeading eyebrow="Inventory overview" title="See what your shelves are telling you" copy="Grounded trends and administrator next steps from every saved shelf scan." />
        <Link className="primary scan-cta" to="/scan"><Camera /> Upload and scan a shelf <ArrowRight /></Link>
      </div>
      {error && <div className="alert error"><AlertTriangle /> {error}</div>}
      {!data ? <LoadingCard /> : (
        <>
          <div className="metrics-grid">
            <Metric label="Saved scans" value={data.summary.num_scans || 0} note="All shelf checks" />
            <Metric label="Products recorded" value={data.summary.total_items || 0} note="Across all scans" />
            <Metric label="Categories seen" value={data.summary.distinct_categories || 0} note="Known categories" />
            <Metric label="Needs review" value={data.summary.unknown_items || 0} note="Unmatched products" tone={data.summary.unknown_items ? 'warn' : 'good'} />
          </div>
          <section className="card insight-summary-card" aria-labelledby="inventory-summary-title">
            <div className="summary-card-head">
              <div>
                <span className="eyebrow">AI inventory briefing</span>
                <h2 id="inventory-summary-title">Full inventory summary</h2>
                <p>Generated only from aggregated inventory and feedback data.</p>
              </div>
              <div className="provider-controls">
                <label>
                  <span>Provider</span>
                  <select
                    value={provider}
                    onChange={(event) => {
                      const nextProvider = event.target.value as AiProviderId
                      const selected = aiConfig?.providers.find((item) => item.id === nextProvider)
                      setProvider(nextProvider)
                      if (selected) setModel(selected.default_model)
                    }}
                  >
                    {aiConfig?.providers.map((item) => (
                      <option key={item.id} value={item.id}>
                        {item.label}{item.available ? '' : ' (unavailable)'}
                      </option>
                    ))}
                  </select>
                </label>
                <label>
                  <span>Model</span>
                  <select value={model} onChange={(event) => setModel(event.target.value)}>
                    {selectedProvider?.models.map((item) => <option value={item} key={item}>{item}</option>)}
                  </select>
                </label>
                <button
                  className="secondary"
                  disabled={summaryLoading || !selectedProvider?.available}
                  onClick={() => refreshSummary()}
                >
                  <RefreshCw className={summaryLoading ? 'spin' : ''} /> {summaryLoading ? 'Generating…' : 'Generate'}
                </button>
              </div>
            </div>
            <p className="provider-description">{selectedProvider?.description}</p>
            {selectedProvider && !selectedProvider.available && (
              <div className="alert warning" role="status"><AlertTriangle /> {selectedProvider.unavailable_reason}</div>
            )}
            {summaryError && <div className="alert error" role="alert"><AlertTriangle /> {summaryError}</div>}
            {summaryLoading && !summary ? <div className="summary-loading" role="status"><RefreshCw className="spin" /> Generating grounded summary…</div> : (
              summary && (
                <div className="overall-summary" aria-live="polite">
                  <Sparkles />
                  <div>
                    <p>{summary.overall_summary}</p>
                    <small>
                      {summary.source === 'llm' ? `${summary.provider} · ${summary.model}` : 'Deterministic fallback'}
                    </small>
                  </div>
                </div>
              )
            )}
            {summary?.warning && <div className="alert warning" role="status"><AlertTriangle /> {summary.warning}</div>}
          </section>
          <div className="analytics-grid">
            <div className="card chart-card"><h2>Most common categories</h2><p>Products recorded across all scans</p>
              {data.categories.length ? <ResponsiveContainer width="100%" height={360}>
                <BarChart data={data.categories.slice(0, 8)} layout="vertical" margin={{ left: 16 }}>
                  <CartesianGrid strokeDasharray="3 3" horizontal={false} />
                  <XAxis type="number" hide />
                  <YAxis dataKey="category" type="category" width={120} tickLine={false} axisLine={false} />
                  <Tooltip cursor={{ fill: '#f5f3ed' }} />
                  <Bar dataKey="count" fill="#176b55" radius={[0, 6, 6, 0]} />
                </BarChart>
              </ResponsiveContainer> : <EmptyState copy="Complete a shelf scan to see category insights." />}
              <ChartNarrative chartId="category_frequency" summary={summary} />
            </div>
            <div className="card chart-card"><h2>Shelf composition</h2><p>Share of identified products by category</p>
              {data.categories.length ? <ResponsiveContainer width="100%" height={360}>
                <PieChart>
                  <Pie data={data.categories.slice(0, 8)} dataKey="count" nameKey="category" innerRadius={68} outerRadius={112} paddingAngle={2}>
                    {data.categories.slice(0, 8).map((entry, index) => <Cell key={entry.category} fill={pieColors[index % pieColors.length]} />)}
                  </Pie>
                  <Tooltip />
                </PieChart>
              </ResponsiveContainer> : <EmptyState copy="Complete a shelf scan to see composition." />}
              <ChartNarrative chartId="shelf_composition" summary={summary} />
            </div>
          </div>
          <div className="analytics-grid">
            <div className="card chart-card"><h2>Products by scan</h2><p>Detected product count over time</p>
              {scanTrend.length ? <ResponsiveContainer width="100%" height={300}>
                <LineChart data={scanTrend}>
                  <CartesianGrid strokeDasharray="3 3" vertical={false} />
                  <XAxis dataKey="scan" tickLine={false} axisLine={false} />
                  <YAxis tickLine={false} axisLine={false} />
                  <Tooltip />
                  <Line type="monotone" dataKey="products" stroke="#176b55" strokeWidth={3} dot={{ r: 4 }} />
                </LineChart>
              </ResponsiveContainer> : <EmptyState copy="Complete more scans to see a trend." />}
              <ChartNarrative chartId="products_by_scan" summary={summary} />
            </div>
            <div className="card chart-card"><h2>Possible empty shelf area</h2><p>Uncovered image area by scan</p>
              {scanTrend.length ? <ResponsiveContainer width="100%" height={300}>
                <LineChart data={scanTrend}>
                  <CartesianGrid strokeDasharray="3 3" vertical={false} />
                  <XAxis dataKey="scan" tickLine={false} axisLine={false} />
                  <YAxis domain={[0, 100]} unit="%" tickLine={false} axisLine={false} />
                  <Tooltip formatter={(value) => [`${value}%`, 'Possible gap']} />
                  <Line type="monotone" dataKey="empty" stroke="#d08a2f" strokeWidth={3} dot={{ r: 4 }} />
                </LineChart>
              </ResponsiveContainer> : <EmptyState copy="Complete a shelf scan to see empty-space trends." />}
              <ChartNarrative chartId="empty_shelf_area" summary={summary} />
            </div>
          </div>
          <div className="analytics-grid">
            <div className="card chart-card"><h2>Subcategory breakdown</h2><p>Most frequently identified product groups</p>
              {data.subcategories.length ? <ResponsiveContainer width="100%" height={320}>
                <BarChart data={data.subcategories.slice(0, 8)} layout="vertical" margin={{ left: 16 }}>
                  <CartesianGrid strokeDasharray="3 3" horizontal={false} />
                  <XAxis type="number" hide />
                  <YAxis dataKey="subcategory" type="category" width={120} tickLine={false} axisLine={false} />
                  <Tooltip cursor={{ fill: '#f5f3ed' }} />
                  <Bar dataKey="count" fill="#4b9c7f" radius={[0, 6, 6, 0]} />
                </BarChart>
              </ResponsiveContainer> : <EmptyState copy="No subcategory information is available yet." />}
              <ChartNarrative chartId="subcategory_breakdown" summary={summary} />
            </div>
            <FeedbackSummary data={data.feedback} />
          </div>
          <RecentScans scans={data.scans.slice(-5).reverse()} />
        </>
      )}
    </>
  )
}

function ChartNarrative({ chartId, summary }: { chartId: InsightChartId; summary: InsightSummary | null }) {
  const chart = summary?.charts[chartId]
  if (!chart) return <div className="chart-narrative pending">Generate a summary for this chart.</div>
  const adminActions = Array.isArray(chart.admin_actions) ? chart.admin_actions : []
  return (
    <div className="chart-narrative">
      <p><Sparkles /> <span>{chart.summary}</span></p>
      <div className="admin-actions">
        <strong>Administrator actions</strong>
        {adminActions.length ? (
          <ul>{adminActions.map((action, index) => <li key={`${action}-${index}`}>{action}</li>)}</ul>
        ) : <span className="no-action"><Check /> No immediate action</span>}
      </div>
    </div>
  )
}

function FeedbackSummary({ data }: { data: Insights['feedback'] }) {
  const categoryTotal = data.category_correct + data.category_incorrect
  const skuTotal = data.sku_correct + data.sku_incorrect
  const categoryRate = categoryTotal ? Math.round((data.category_correct / categoryTotal) * 100) : 0
  const skuRate = skuTotal ? Math.round((data.sku_correct / skuTotal) * 100) : 0
  return (
    <div className="card feedback-insight">
      <div><span className="soft-icon"><MessageSquareCheck /></span><h2>Human feedback</h2><p>Validation collected from product reviews</p></div>
      <div className="feedback-stat"><span><strong>Category accepted</strong><small>{categoryTotal} responses</small></span><b>{categoryTotal ? `${categoryRate}%` : '—'}</b></div>
      <div className="quality-track"><span style={{ width: `${categoryRate}%` }} /></div>
      <div className="feedback-stat"><span><strong>SKU reading accepted</strong><small>{skuTotal} responses</small></span><b>{skuTotal ? `${skuRate}%` : '—'}</b></div>
      <div className="quality-track"><span style={{ width: `${skuRate}%` }} /></div>
      <div className="feedback-counts"><span>{data.category_incorrect} category corrections</span><span>{data.sku_incorrect} SKU corrections</span></div>
    </div>
  )
}

function RecentScans({ scans }: { scans: ScanHistory[] }) {
  return <div className="card recent-card"><h2>Recent shelf checks</h2><p>Your latest saved scans</p>
    {scans.length ? scans.map((scan) => <div className="history-row" key={scan.id}><span className="soft-icon"><ScanLine /></span><div><strong>{scan.image_name}</strong><small>{formatDate(scan.ts)} · {scan.num_items} products</small></div><span>{Math.round(scan.empty_pct * 100)}% gap</span></div>) : <EmptyState copy="Your latest scans will appear here." />}
  </div>
}

function HistoryPage() {
  const [scans, setScans] = useState<ScanHistory[] | null>(null)
  const [error, setError] = useState('')
  useEffect(() => { getHistory().then((payload) => setScans(payload.scans)).catch((reason) => setError(reason.message)) }, [])
  return (
    <>
      <PageHeading eyebrow="Saved activity" title="Shelf scan history" copy="Review when shelves were checked and what each scan found." />
      {error && <div className="alert error"><AlertTriangle /> {error}</div>}
      {!scans ? <LoadingCard /> : <div className="card history-card">
        {scans.length ? scans.map((scan) => (
          <div className="history-entry" key={scan.id}>
            <span className="history-icon"><ScanLine /></span>
            <div><strong>{scan.image_name}</strong><small>Scan #{scan.id} · {formatDate(scan.ts)}</small></div>
            <div><strong>{scan.num_items}</strong><small>products</small></div>
            <div><strong>{scan.distinct_categories}</strong><small>categories</small></div>
            <div><strong>{scan.review_count}</strong><small>to review</small></div>
            <span className={`gap-badge ${scan.empty_pct >= .55 ? 'high' : ''}`}>{Math.round(scan.empty_pct * 100)}% possible gap</span>
          </div>
        )) : <EmptyState copy="No scans yet. Start with a shelf photo." />}
      </div>}
    </>
  )
}

const suggestedQuestions = [
  'How many products were detected?',
  'What are the top 5 categories?',
  'Which items need manual review?',
  'How has the product count changed over time?',
]

function AskPage() {
  const [question, setQuestion] = useState('')
  const [answer, setAnswer] = useState('')
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')
  const ask = async (text = question) => {
    if (!text.trim()) return
    setQuestion(text)
    setLoading(true)
    setError('')
    try { setAnswer((await askInventory(text)).text) } catch (reason) { setError(reason instanceof Error ? reason.message : 'Could not answer that question.') } finally { setLoading(false) }
  }
  return (
    <>
      <PageHeading eyebrow="Inventory assistant" title="Ask in everyday language" copy="Get a quick answer using the shelf scans saved in this workspace." />
      <div className="ask-grid">
        <div className="card ask-card">
          <span className="ask-orb"><Sparkles /></span>
          <h2>What would you like to know?</h2>
          <div className="question-box"><input value={question} onChange={(event) => setQuestion(event.target.value)} onKeyDown={(event) => { if (event.key === 'Enter') ask() }} placeholder="Ask about products, categories, gaps or trends…" aria-label="Inventory question" /><button onClick={() => ask()} disabled={loading || question.trim().length < 2}>{loading ? <RefreshCw className="spin" /> : <ArrowRight />}</button></div>
          {error && <div className="alert error"><AlertTriangle /> {error}</div>}
          {answer && <div className="answer" aria-live="polite"><span><Sparkles /></span><div><small>ShelfSight answer</small><p>{answer.replaceAll('**', '')}</p></div></div>}
        </div>
        <div className="card suggestions"><h3>Try asking</h3>{suggestedQuestions.map((item) => <button key={item} onClick={() => ask(item)}>{item}<ChevronRight /></button>)}</div>
      </div>
    </>
  )
}

function LoadingCard() {
  return <div className="card loading-card"><RefreshCw className="spin" /><p>Loading shelf information…</p></div>
}

function EmptyState({ copy }: { copy: string }) {
  return <div className="empty-state"><Clock3 /><p>{copy}</p></div>
}

function formatDate(value: string) {
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? value : date.toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' })
}

export default function App() {
  return <BrowserRouter><Shell /></BrowserRouter>
}
