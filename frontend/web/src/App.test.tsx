import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import App from './App'
import * as api from './api'

vi.mock('./api')

const completeJob = {
  job_id: 'job-1',
  status: 'complete' as const,
  stage: 'complete',
  progress: 100,
  message: 'Shelf report ready',
  result: {
    scan_id: 7,
    image_name: 'shelf.jpg',
    annotated_image: 'data:image/jpeg;base64,test',
    summary: {
      num_items: 2,
      distinct_categories: 1,
      empty_pct: 0.3,
      empty_label: 'Moderate',
      shelf_type: 'Category-specific',
      review_count: 1,
    },
    detections: [
      {
        crop_id: 1,
        category: 'Soft drinks',
        subcategory: 'Cola',
        score: 0.12,
        area: 200,
        box: [1, 2, 3, 4],
        brand: 'Acme',
        product_name: 'Cola',
        sku_text: 'ACME COLA',
        sku_needs_review: 0,
      },
      {
        crop_id: 2,
        category: 'unknown',
        subcategory: 'unknown',
        score: 0,
        area: 100,
        box: [5, 6, 7, 8],
        sku_needs_review: 1,
      },
    ],
    timings: { yolo_s: 0.4, classify_s: 1.2 },
  },
}

const aiConfig = {
  default_provider: 'gemini' as const,
  providers: [
    {
      id: 'gemini' as const,
      label: 'Gemini',
      available: true,
      description: 'Gemini on Vertex AI.',
      default_model: 'gemini-2.5-flash',
      models: ['gemini-2.5-flash'],
      unavailable_reason: '',
    },
    {
      id: 'openrouter' as const,
      label: 'OpenRouter',
      available: false,
      description: 'OpenRouter.',
      default_model: 'google/gemini-2.5-flash',
      models: ['google/gemini-2.5-flash'],
      unavailable_reason: 'OPENROUTER_API_KEY is not configured on the server.',
    },
  ],
}

const insights = {
  summary: { total_items: 2, distinct_categories: 1, unknown_items: 0, num_scans: 1 },
  categories: [{ category: 'Soft drinks', count: 2 }],
  subcategories: [{ subcategory: 'Cola', count: 2 }],
  scans: [],
  feedback: { total: 0, category_correct: 0, category_incorrect: 0, sku_correct: 0, sku_incorrect: 0 },
}

const insightSummary = {
  overall_summary: 'Two products are recorded.',
  charts: {
    category_frequency: { summary: 'Soft drinks leads.', admin_actions: [] },
    shelf_composition: { summary: 'Soft drinks represents all products.', admin_actions: [] },
    products_by_scan: { summary: 'One scan is available.', admin_actions: [] },
    empty_shelf_area: { summary: 'No gap trend is available.', admin_actions: [] },
    subcategory_breakdown: { summary: 'Cola leads.', admin_actions: [] },
  },
  source: 'llm' as const,
  provider: 'gemini' as const,
  model: 'gemini-2.5-flash',
  warning: '',
}

describe('ShelfSight operator experience', () => {
  beforeEach(() => {
    vi.resetAllMocks()
    window.history.pushState({}, '', '/')
    vi.mocked(api.getAiConfig).mockResolvedValue(aiConfig)
    vi.mocked(api.getInsights).mockResolvedValue(insights)
    vi.mocked(api.generateInsightSummary).mockResolvedValue(insightSummary)
  })

  it('shows insights as the landing page with a shelf scan action', async () => {
    render(<App />)

    expect(screen.getByRole('heading', { name: /see what your shelves/i })).toBeInTheDocument()
    expect(window.location.pathname).toBe('/insights')
    expect(screen.getByRole('link', { name: /upload and scan a shelf/i })).toHaveAttribute('href', '/scan')
    await waitFor(() => expect(screen.getByText('Two products are recorded.')).toBeInTheDocument())
    expect(screen.getAllByText(/no immediate action/i)).toHaveLength(5)
    expect(screen.queryByText(/demo store/i)).not.toBeInTheDocument()
  })

  it('keeps inventory charts available when AI configuration fails', async () => {
    vi.mocked(api.getAiConfig).mockRejectedValue(new Error('AI options unavailable'))

    render(<App />)

    await waitFor(() => expect(screen.getByText('Products recorded')).toBeInTheDocument())
    expect(screen.getByRole('heading', { name: 'Most common categories' })).toBeInTheDocument()
    expect(screen.getByRole('alert')).toHaveTextContent('AI options unavailable')
  })

  it('refreshes current insights safely after returning from the scan route', async () => {
    const refreshedInsights = {
      ...insights,
      summary: { total_items: 60, distinct_categories: 11, unknown_items: 0, num_scans: 1 },
      scans: [{
        id: 8,
        ts: '2026-07-19T02:38:02',
        image_name: 'shelf_05.jpg',
        num_items: 60,
        distinct_categories: 11,
        empty_pct: 0.593,
        shelf_type: 'Mixed',
        review_count: 0,
      }],
    }
    const providerSummaryWithMissingActions = {
      ...insightSummary,
      overall_summary: 'The latest scan recorded 60 products.',
      charts: {
        ...insightSummary.charts,
        category_frequency: {
          summary: 'Deodorants lead the latest scan.',
          admin_actions: null,
        },
      },
    } as unknown as typeof insightSummary
    vi.mocked(api.getInsights)
      .mockResolvedValueOnce(insights)
      .mockResolvedValueOnce(refreshedInsights)
    vi.mocked(api.generateInsightSummary)
      .mockResolvedValueOnce(insightSummary)
      .mockResolvedValueOnce(providerSummaryWithMissingActions)

    render(<App />)
    await waitFor(() => expect(screen.getByText('Two products are recorded.')).toBeInTheDocument())
    fireEvent.click(screen.getByRole('link', { name: /^scan shelf$/i }))
    expect(screen.getByRole('heading', { name: /turn a shelf photo/i })).toBeInTheDocument()
    expect(vi.mocked(api.getInsights).mock.calls[0][0]?.aborted).toBe(true)
    expect(vi.mocked(api.generateInsightSummary).mock.calls[0][2]?.aborted).toBe(true)
    fireEvent.click(screen.getByRole('link', { name: /^insights$/i }))

    await waitFor(() => expect(screen.getByText('The latest scan recorded 60 products.')).toBeInTheDocument())
    expect(screen.getByText('shelf_05.jpg')).toBeInTheDocument()
    expect(screen.getByText('Deodorants lead the latest scan.')).toBeInTheDocument()
    expect(screen.getAllByText(/no immediate action/i)).toHaveLength(5)
  })

  it('rejects a non-image file with plain-language guidance', () => {
    window.history.pushState({}, '', '/scan')
    const { container } = render(<App />)
    const input = container.querySelector('input[type="file"]') as HTMLInputElement

    fireEvent.change(input, { target: { files: [new File(['text'], 'notes.txt', { type: 'text/plain' })] } })

    expect(screen.getByRole('alert')).toHaveTextContent(/choose a jpg, png, bmp, or webp/i)
  })

  it('renders actionable results after a completed analysis', async () => {
    window.history.pushState({}, '', '/scan')
    vi.mocked(api.startAnalysis).mockResolvedValue('job-1')
    vi.mocked(api.getAnalysis).mockResolvedValue(completeJob)
    const { container } = render(<App />)
    const input = container.querySelector('input[type="file"]') as HTMLInputElement
    fireEvent.change(input, { target: { files: [new File(['image'], 'shelf.jpg', { type: 'image/jpeg' })] } })

    const analyzeButton = container.querySelector('.analyze-button') as HTMLButtonElement
    await waitFor(() => expect(analyzeButton).toBeEnabled())
    fireEvent.click(analyzeButton)

    await waitFor(() => expect(screen.getByRole('heading', { name: /shelf report is ready/i })).toBeInTheDocument())
    expect(api.startAnalysis).toHaveBeenCalledWith(
      expect.any(File),
      {
        maxCrops: 60,
        maxSkuCrops: 5,
        extractSku: true,
        skuProvider: 'gemini',
        skuModel: 'gemini-2.5-flash',
      },
    )
    expect(screen.getByRole('button', { name: /analyze shelf/i })).toBeEnabled()
    expect(screen.queryByText(/analysis in progress/i)).not.toBeInTheDocument()
    expect(screen.getByText('Soft drinks')).toBeInTheDocument()
    expect(screen.getByText(/category could not be matched/i)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /download report/i })).toBeInTheDocument()

    fireEvent.click(screen.getAllByRole('button', { name: /review ai/i })[0])
    fireEvent.click(screen.getAllByRole('button', { name: /^correct$/i })[0])
    await waitFor(() => expect(api.sendDetectionFeedback).toHaveBeenCalledWith({
      scanId: 7,
      cropId: 1,
      feedbackType: 'category',
      verdict: 'correct',
      correction: '',
    }))
  })
})
