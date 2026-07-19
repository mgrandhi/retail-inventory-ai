import { describe, expect, it } from 'vitest'
import { normalizeInsightSummary } from './api'

describe('insight summary response normalization', () => {
  it('treats missing administrator actions as an empty action list', () => {
    const result = normalizeInsightSummary({
      overall_summary: 'Current inventory summary.',
      charts: {
        category_frequency: {
          summary: 'Deodorants lead.',
          admin_actions: null,
        },
      },
      source: 'llm',
      provider: 'gemini',
      model: 'gemini-2.5-flash',
      warning: '',
    })

    expect(result.charts.category_frequency).toEqual({
      summary: 'Deodorants lead.',
      admin_actions: [],
    })
    expect(result.source).toBe('llm')
  })

  it('rejects a response without an overall summary', () => {
    expect(() => normalizeInsightSummary({ charts: {} })).toThrow(
      'The inventory summary response was incomplete. Please generate it again.',
    )
  })

  it('does not label an incomplete provider response as LLM generated', () => {
    const result = normalizeInsightSummary({
      overall_summary: 'Fallback summary.',
      charts: {},
      source: 'llm',
      provider: null,
      model: null,
    })

    expect(result.source).toBe('deterministic')
  })
})
