// MedRPG LLM proxy server
// Receives prompt + system from Godot client, forwards to Anthropic Claude API,
// returns the model's text response.

require('dotenv').config();
const express = require('express');
const cors = require('cors');
const Anthropic = require('@anthropic-ai/sdk').default;

const PORT = process.env.PORT || 3000;
const MODEL = 'claude-sonnet-4-5-20250929';

if (!process.env.ANTHROPIC_API_KEY) {
  console.error('ERROR: ANTHROPIC_API_KEY not found in .env');
  process.exit(1);
}

const anthropic = new Anthropic({
  apiKey: process.env.ANTHROPIC_API_KEY,
});

const app = express();
app.use(cors());
app.use(express.json({ limit: '1mb' }));

app.post('/llm', async (req, res) => {
  const { prompt, system, max_tokens } = req.body || {};

  if (typeof prompt !== 'string' || typeof system !== 'string') {
    return res.status(400).json({
      response: '',
      error: 'Request body must include string fields: prompt, system',
    });
  }

  console.log(`[/llm] prompt=${prompt.length} chars, system=${system.length} chars`);

  try {
    const message = await anthropic.messages.create({
      model: MODEL,
      max_tokens: typeof max_tokens === 'number' ? max_tokens : 256,
      system: system,
      messages: [{ role: 'user', content: prompt }],
    });

    // The Anthropic SDK returns content as an array of blocks.
    // For plain text responses we expect a single text block.
    const textBlocks = (message.content || []).filter((b) => b.type === 'text');
    const text = textBlocks.map((b) => b.text).join('');

    console.log(`[/llm] response=${text.length} chars`);
    res.json({ response: text });
  } catch (err) {
    console.error('[/llm] Anthropic API error:', err.message || err);
    res.status(500).json({
      response: '',
      error: err.message || 'Unknown error calling Anthropic API',
    });
  }
});

app.get('/health', (_req, res) => {
  res.json({ status: 'ok', model: MODEL });
});

app.listen(PORT, () => {
  console.log(`MedRPG LLM server listening on http://localhost:${PORT}`);
  console.log(`Model: ${MODEL}`);
});
