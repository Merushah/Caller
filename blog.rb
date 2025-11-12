# blog.rb
# Sinatra routes for the Blog generator page (Gemini integration)
# Requires GEMINI_API_KEY in your .env

require 'sinatra'
require 'erb'
require 'net/http'
require 'uri'
require 'json'
require 'dotenv/load'   # loads .env into ENV

# ---------- Helper ----------
# Extract first JSON array/object from arbitrary text
def extract_first_json(text)
  return nil unless text.is_a?(String)
  arr_match = text.match(/\[[\s\S]*\]/m)
  obj_match = text.match(/\{[\s\S]*\}/m)
  arr_match ? arr_match[0] : obj_match ? obj_match[0] : nil
end

# ---- SERVER-SIDE API: /api/generate_articles (Gemini) ----
post '/api/generate_articles' do
  content_type 'application/json'

  payload = JSON.parse(request.body.read || '{}') rescue {}
  titles = payload['titles'] || []
  unless titles.is_a?(Array) && titles.any?
    halt 400,({ error: 'missing titles' }.to_json)
  end

  # Input validation
  if titles.size > 30
    halt 400,({ error: 'too many titles (max 30)' }.to_json)
  end
  if titles.any? { |t| t.to_s.length > 500 }
    halt 400,({ error: 'each title must be < 500 characters' }.to_json)
  end

  api_key = ENV['GEMINI_API_KEY'] || ENV['OPENROUTER_API_KEY']
  model   = ENV['GEMINI_MODEL'] || 'gemini-2.0-flash'
  unless api_key && !api_key.empty?
    status 500
    return({ error: 'Missing GEMINI_API_KEY in environment.' }.to_json)
  end

  prompt = <<~PROMPT
    You are a helpful assistant that writes developer-focused blog post drafts.
    For each title provided, produce an array of objects with:
    - title
    - excerpt (2–3 sentence preview)
    - lead (intro paragraph)
    - bullets (3 short bullet points)
    - conclusion (short wrap-up)

    Input titles:
    #{titles.map.with_index { |t, i| "#{i+1}. #{t}" }.join("\n")}

    Output only a valid JSON array of objects as specified. No commentary, no markdown, only JSON.
  PROMPT

  uri = URI("https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent?key=#{api_key}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.open_timeout = 6
  http.read_timeout = 30

# Build request body with generationConfig (temperature, maxOutputTokens must be inside generationConfig)
body = {
  contents: [
    { parts: [{ text: prompt }] }
  ],
  # put generation options inside generationConfig
  generationConfig: {
    temperature: 0.3,
    maxOutputTokens: 800
    # you can also add: topP: 0.95, topK: 40, candidateCount: 1, responseMimeType: "text/plain"
  }
}.to_json


  req = Net::HTTP::Post.new(uri.request_uri)
  req['Content-Type'] = 'application/json'
  req['User-Agent'] = "DevBlogGenerator/1.0"
  req.body = body

  begin
    res = http.request(req)
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    status 504
    return({ error: "Timeout when calling Gemini API: #{e.message}" }.to_json)
  rescue => e
    status 502
    return({ error: "Failed to reach Gemini API: #{e.message}" }.to_json)
  end

  raw = res.body || ''
  unless res.is_a?(Net::HTTPSuccess)
    puts "[Gemini] non-200 status=#{res.code} body=#{raw[0..1000]}"
    case res.code.to_i
    when 401, 403
      status 502
      return({ error: "Authentication/authorization error from Gemini (#{res.code}). Check API key and permissions.", details: raw }.to_json)
    when 429
      status 429
      return({ error: "Rate limited by Gemini (429). Try again later.", details: raw }.to_json)
    else
      status 502
      return({ error: "Gemini API returned an error (#{res.code})", details: raw }.to_json)
    end
  end

  # Try parse JSON quickly
  begin
    data = JSON.parse(raw)
  rescue JSON::ParserError
    data = nil
  end

  # attempt to pull generated text if model returned non-JSON top-level
  generated_text = nil
  if data
    generated_text = data.dig('candidates', 0, 'content', 'parts', 0) ||
                     data.dig('candidates', 0, 'content', 0, 'text') ||
                     data.dig('output', 0, 'content', 0, 'text')
    if generated_text.is_a?(Hash) && generated_text['text']
      generated_text = generated_text['text']
    end
  end

  # helper to shorten text to max lines (fallback to sentences if no lines)
  def shorten_text_lines(text, max_lines = 5, max_chars = 400)
    return nil unless text && text.is_a?(String)
    # split by line breaks first
    lines = text.strip.split(/\r?\n/).map(&:strip).reject(&:empty?)
    if lines.any?
      out = lines.first(max_lines).join("\n")
      return out.length <= max_chars ? out : out[0...max_chars].rstrip + "…"
    end
    # fallback: split into sentences and take up to max_lines sentences
    sentences = text.strip.split(/(?<=[\.!?])\s+/)
    out = sentences.first(max_lines).join(' ')
    return out.length <= max_chars ? out : out[0...max_chars].rstrip + "…"
  end

  # normalize article object shape and enforce excerpt / bullets limits
  def normalize_articles(arr, generated_text_fallback = nil)
    return [] unless arr.is_a?(Array)
    arr.map do |raw|
      article = raw.is_a?(Hash) ? raw.dup : {}

      # ensure title exists
      article['title'] = (article['title'] || article['heading'] || article['name'] || 'Untitled').to_s

      # Ensure bullets is an array and trim to 3
      if article['bullets'].is_a?(Array)
        article['bullets'] = article['bullets'].map(&:to_s).map(&:strip).reject(&:empty?).first(3)
      else
        article['bullets'] = []
      end

      # Create excerpt if missing, prefer excerpt -> lead -> generated_text_fallback -> join of other fields
      source_for_excerpt = article['excerpt'] || article['lead'] || generated_text_fallback || article.values.join(' ')
      article['excerpt'] = shorten_text_lines(source_for_excerpt.to_s, 5, 400) || ''

      # Trim lead and conclusion lightly
      article['lead'] = shorten_text_lines(article['lead'].to_s, 8, 800) if article['lead']
      article['conclusion'] = shorten_text_lines(article['conclusion'].to_s, 4, 400) if article['conclusion']

      # keep only the fields we care about (optional - helps front end)
      {
        'title' => article['title'],
        'detail' => article['detail'] || article['category'] || '',
        'excerpt' => article['excerpt'],
        'lead' => article['lead'] || '',
        'bullets' => article['bullets'],
        'conclusion' => article['conclusion'] || ''
      }
    end
  end

  # If we have a parsed array (direct JSON from model), use that
  parsed_array = nil
  if data.is_a?(Array)
    parsed_array = data
  elsif data.is_a?(Hash)
    # If model returned a hash that contains array inside, try to find it
    parsed_array = data['articles'] if data['articles'].is_a?(Array)
    parsed_array ||= data['items'] if data['items'].is_a?(Array)
    parsed_array ||= data['results'] if data['results'].is_a?(Array)
  end

  # If we didn't get parsed array, attempt to extract JSON array/object from generated_text or raw
  if parsed_array.nil?
    text_candidate = generated_text || raw
    json_part = extract_first_json(text_candidate)
    if json_part
      begin
        parsed_guess = JSON.parse(json_part)
        parsed_array = parsed_guess if parsed_guess.is_a?(Array)
        # if parsed_guess is an object with array inside, try to find obvious keys
        if parsed_array.nil? && parsed_guess.is_a?(Hash)
          parsed_array = parsed_guess['articles'] if parsed_guess['articles'].is_a?(Array)
          parsed_array ||= parsed_guess['items'] if parsed_guess['items'].is_a?(Array)
        end
      rescue JSON::ParserError
        parsed_array = nil
      end
    end
  end

  # If still nil, try one more time: if data has candidates with text that is JSON array
  if parsed_array.nil? && data.is_a?(Hash) && data['candidates']
    cand_text = if data['candidates'][0].is_a?(Hash)
                  part = data['candidates'][0]['content'] || data['candidates'][0]
                  part.is_a?(Hash) ? part.values.join(' ') : part.to_s
                else
                  data['candidates'][0].to_s
                end
    json_part = extract_first_json(cand_text.to_s)
    if json_part
      begin
        parsed_guess = JSON.parse(json_part)
        parsed_array = parsed_guess if parsed_guess.is_a?(Array)
      rescue JSON::ParserError
        parsed_array = nil
      end
    end
  end

  # Final fallback: return a synthetic article per title if nothing parseable found
  if parsed_array.nil? || !parsed_array.is_a?(Array) || parsed_array.empty?
    # Build minimal synthetic responses: make small 4-line excerpt from prompt + title
    synthetic = titles.first(10).map do |t|
      {
        'title' => t.to_s,
        'detail' => '',
        'excerpt' => shorten_text_lines("Draft for #{t}: This is a short preview generated as a fallback. You can regenerate to get a full draft.", 4, 300),
        'lead' => '',
        'bullets' => [],
        'conclusion' => ''
      }
    end
    return({ articles: synthetic }.to_json)
  end

  # We did parse an array — normalize and enforce limits
  normalized = normalize_articles(parsed_array, generated_text)
  # Return only first 10
  { articles: normalized.first(10) }.to_json
end


# ---- CLIENT UI: /blog ----
get '/blog' do
  content_type 'text/html'
  erb <<-HTML
  <!doctype html>
  <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width,initial-scale=1" />
      <title>Dev Blog Generator</title>
      <style>
        body { font-family: 'Inter', sans-serif; background:#071127; color:#e6eef6; margin:0; padding:24px; }
        .wrap { max-width: 1000px; margin: 0 auto; }
        .top { display:flex; align-items:center; justify-content:space-between; gap:12px; margin-bottom:18px; }
        .brand { display:flex; align-items:center; gap:12px; }
        .logo { width:44px;height:44px;border-radius:10px;background:linear-gradient(135deg,#60a5fa,#0ea5a4);display:flex;align-items:center;justify-content:center;color:#041a1f;font-weight:700; }
        h1{margin:0;font-size:20px} .sub { color:#9aa4b2;font-size:13px;margin-top:6px; }
        a.link { color:#60a5fa; text-decoration:none; background:rgba(255,255,255,0.02); padding:8px 12px; border-radius:8px; border:1px solid rgba(255,255,255,0.03); }

        .panel { background: rgba(255,255,255,0.02); padding:18px; border-radius:12px; border:1px solid rgba(255,255,255,0.03); margin-bottom:18px; }
        label{color:#b8c0d0;font-size:13px}
        textarea{width:100%;min-height:110px;padding:12px;border-radius:10px;border:1px solid rgba(255,255,255,0.06);background:transparent;color:inherit;font-size:14px}
        .row{display:flex;gap:10px;margin-top:10px;align-items:center}
        button { padding:10px 14px;border-radius:8px;border:none;font-weight:700; cursor:pointer; }
        .primary{background:linear-gradient(90deg,#60a5fa,#0ea5a4); color:#041a1f}
        .ghost{background:transparent;border:1px solid rgba(255,255,255,0.05); color:#9aa4b2}

        .articles { display:grid; grid-template-columns: repeat(auto-fill,minmax(300px,1fr)); gap:14px; }
        .article { background: rgba(0,0,0,0.25); border-radius:10px;padding:14px; border:1px solid rgba(255,255,255,0.03); min-height:120px; display:flex;flex-direction:column; }
        .article h3 { margin:0 0 8px 0; font-size:16px }
        .meta { color:#9aa4b2;font-size:12px;margin-bottom:8px }
        .excerpt { color:#dce7f6;font-size:14px; margin-bottom:8px; flex:1; }
        .readmore { font-size:13px;color:#60a5fa;font-weight:700; text-decoration:none; }

        .controls { display:flex; gap:8px; flex-wrap:wrap; margin-top:8px }
        .note { color:#9aa4b2; font-size:13px; margin-top:8px }

        pre { white-space: pre-wrap; word-break: break-word; font-family: inherit; color: #dce7f6; background: rgba(255,255,255,0.02); padding:12px; border-radius:8px; }
      </style>
    </head>
    <body>
      <div class="wrap">
        <div class="top">
          <div class="brand">
            <div class="logo">BL</div>
            <div>
              <h1>Dev Blog — Generator</h1>
              <div class="sub">Type titles (one per line). Optionally add short details after " - ". Click Generate to produce article drafts.</div>
            </div>
          </div>
          <div>
            <a class="link" href="/">← Back to Calls</a>
          </div>
        </div>

        <div class="panel">
          <label for="prompt">AI Prompt — enter list of titles (one per line). Optionally: <code>Title - short detail</code></label>
          <textarea id="prompt" placeholder="E.g.
Building a REST API with Sinatra - step-by-step for beginners
Understanding Ruby blocks - examples and common pitfalls"></textarea>

          <div class="controls" style="margin-top:12px">
            <button class="primary" id="generateBtn">Generate Content</button>
            <button class="ghost" id="sampleBtn">Auto-generate 10 samples</button>
            <button class="ghost" id="clearBtn">Clear</button>
            <div style="margin-left:auto" class="note">Tip: paste titles or press Auto-generate to see samples.</div>
          </div>
        </div>

        <div id="articlesWrap" class="panel">
          <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px">
            <strong>Articles</strong>
            <div class="note">Generated articles appear below. Click "Show more" to expand the full draft inside the card.</div>
          </div>
          <div id="articles" class="articles"></div>
        </div>
      </div>

      <script>
        const sampleTitles = [
          "Building a REST API with Sinatra - a beginner's guide",
          "Understanding Ruby blocks - practical examples",
          "Async in JavaScript - promises, async/await explained",
          "Introduction to Docker for developers",
          "Getting started with PostgreSQL - essentials",
          "A practical guide to unit testing in Python",
          "How to deploy a Node.js app to production",
          "Functional programming basics in JavaScript",
          "An intro to CI/CD pipelines with GitHub Actions",
          "Debugging techniques every developer should know"
        ];

        function parsePrompt(text) {
          const lines = text.split('\\n').map(l => l.trim()).filter(Boolean);
          return lines.map(l => {
            const parts = l.split(' - ');
            return { title: parts[0].trim(), detail: parts.slice(1).join(' - ').trim() };
          });
        }

        function escapeHtml(str) {
          if (!str) return '';
          return str.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
        }

        // preview helpers
        function previewText(a) {
          if (a.excerpt && a.excerpt.trim()) return a.excerpt.trim();
          if (a.lead && a.lead.trim()) return a.lead.trim();
          if (Array.isArray(a.bullets) && a.bullets.length) {
            return a.bullets.slice(0, 2).join(' • ');
          }
          return "No preview available. Click Show more to view draft.";
        }

        function truncateText(text, n = 220) {
          if (!text) return "";
          if (text.length <= n) return text;
          return text.slice(0, n).replace(/\s+[^\s]*$/, '') + '…';
        }

        function renderArticles(list) {
          const container = document.getElementById('articles');
          container.innerHTML = '';
          if (!list || !list.length) {
            container.innerHTML = '<div style="color:#9aa4b2">No articles yet.</div>';
            return;
          }

          const shown = list.slice(0, 10);

          shown.forEach((a, idx) => {
            const el = document.createElement('div');
            el.className = 'article';

            const pText = previewText(a);
            const shortPreview = truncateText(pText, 220);

            let bulletsHtml = '';
            if (Array.isArray(a.bullets) && a.bullets.length) {
              bulletsHtml = '<ul style="margin:8px 0 0 18px;padding:0;color:#dce7f6">';
              a.bullets.forEach(b => bulletsHtml += `<li style="margin:4px 0;font-size:13px">${escapeHtml(b)}</li>`);
              bulletsHtml += '</ul>';
            }

            const fullDraftParts = [];
            fullDraftParts.push('# ' + (a.title || 'Untitled'));
            if (a.detail) fullDraftParts.push('_' + a.detail + '_');
            if (a.lead) fullDraftParts.push('\\n' + a.lead);
            if (Array.isArray(a.bullets) && a.bullets.length) {
              fullDraftParts.push('\\n## Key points\\n' + a.bullets.map(b => '- ' + b).join('\\n'));
            }
            if (a.conclusion) fullDraftParts.push('\\n## Conclusion\\n' + a.conclusion);
            const fullDraft = fullDraftParts.join('\\n\\n');

            el.innerHTML = `
              <h3>${escapeHtml(a.title || 'Untitled')}</h3>
              <div class="meta">${escapeHtml(a.detail || 'Programming')}</div>
              <div class="excerpt">${escapeHtml(shortPreview)}</div>
              ${bulletsHtml}
              <div style="margin-top:10px;display:flex;align-items:center;gap:8px">
                <button class="ghost inline-toggle" data-idx="${idx}" style="padding:6px 10px;border-radius:6px;font-weight:700">Show more</button>
              </div>
              <div class="full-draft" style="display:none;margin-top:12px;border-top:1px dashed rgba(255,255,255,0.03);padding-top:12px;">
                <pre style="white-space:pre-wrap;word-break:break-word;font-family:inherit;color:#dce7f6;background:transparent;border:none;padding:0;">${escapeHtml(fullDraft)}</pre>
              </div>
            `;

            const toggleBtn = el.querySelector('.inline-toggle');
            const fullDiv = el.querySelector('.full-draft');
            toggleBtn.addEventListener('click', (e) => {
              e.preventDefault();
              if (fullDiv.style.display === 'none' || fullDiv.style.display === '') {
                fullDiv.style.display = 'block';
                toggleBtn.textContent = 'Show less';
              } else {
                fullDiv.style.display = 'none';
                toggleBtn.textContent = 'Show more';
              }
            });

            container.appendChild(el);
          });

          // show note if more than 10
          const existingNote = document.querySelector('#articlesWrap .client-note');
          if (list.length > 10 && !existingNote) {
            const note = document.createElement('div');
            note.className = 'note client-note';
            note.style.marginTop = '12px';
            note.textContent = `Showing 10 of ${list.length} articles.`;
            document.getElementById('articlesWrap').appendChild(note);
          }
        }

        async function generateArticles(titles) {
          const res = await fetch('/api/generate_articles', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ titles })
          });
          return res.json();
        }

        document.getElementById('generateBtn').addEventListener('click', async () => {
          const text = document.getElementById('prompt').value.trim();
          if (!text) { alert('Please enter titles first.'); return; }
          const parsed = parsePrompt(text);
          const titles = parsed.map(p => (p.detail ? p.title + ' - ' + p.detail : p.title));
          document.getElementById('articles').innerHTML = '<div class="article">Generating articles…</div>';
          try {
            const result = await generateArticles(titles);
            if (result.articles && Array.isArray(result.articles)) {
              renderArticles(result.articles.slice(0, 10));
            } else if (result.raw) {
              document.getElementById('articles').innerHTML = '<pre>' + escapeHtml(result.raw) + '</pre>';
            } else if (result.articles_response) {
              const obj = result.articles_response;
              if (Array.isArray(obj)) {
                renderArticles(obj.slice(0, 10));
              } else {
                document.getElementById('articles').innerHTML = '<pre>' + escapeHtml(JSON.stringify(obj, null, 2)) + '</pre>';
              }
            } else {
              document.getElementById('articles').innerHTML = '<div style="color:#9aa4b2">No content returned.</div>';
            }
          } catch (err) {
            document.getElementById('articles').innerHTML = '<div style="color:#ef4444">Error: ' + escapeHtml(err.message) + '</div>';
          }
        });

        document.getElementById('sampleBtn').addEventListener('click', () => {
          document.getElementById('prompt').value = sampleTitles.join('\\n');
          document.getElementById('generateBtn').click();
        });

        document.getElementById('clearBtn').addEventListener('click', () => {
          document.getElementById('prompt').value = '';
          document.getElementById('articles').innerHTML = '';
        });
      </script>
    </body>
  </html>
  HTML
end
