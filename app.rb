# app.rb (replace or merge with your existing file)
require 'dotenv/load'
require 'sinatra'
require 'twilio-ruby'
require 'json'
require 'erb'
require 'webrick'
require 'csv'
require_relative './blog'
set :server, :webrick

set :bind, '0.0.0.0'
set :port, ENV.fetch('PORT', 4567).to_i


CALLS = {}

before do
  content_type 'application/json' if request.path_info.start_with?('/api/')
end

helpers do
  def twilio_client
    account_sid = ENV['TWILIO_ACCOUNT_SID']
    auth_token  = ENV['TWILIO_AUTH_TOKEN']
    raise "Set TWILIO_ACCOUNT_SID and TWILIO_AUTH_TOKEN environment variables" unless account_sid && auth_token
    Twilio::REST::Client.new(account_sid, auth_token)
  end

  def from_number
    ENV['TWILIO_FROM_NUMBER'] || raise("Set TWILIO_FROM_NUMBER environment variable to your Twilio number (e.g. +1415xxxx)")
  end
end

get '/' do
  content_type 'text/html'
  erb <<-HTML
  <!doctype html>
  <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width,initial-scale=1" />
      <title>Twilio Call Interface</title>
      <style>
        body {
          font-family: 'Inter', sans-serif;
          background: #0a1220;
          color: #e6eef6;
          margin: 0;
          padding: 20px;
        }
        .container {
          max-width: 900px;
          margin: 0 auto;
        }
        .header {
          display: flex;
          align-items: center;
          margin-bottom: 25px;
        }
        .logo {
          width: 45px;
          height: 45px;
          border-radius: 10px;
          background: linear-gradient(135deg, #0ea5a4, #60a5fa);
          display: flex;
          align-items: center;
          justify-content: center;
          font-weight: 700;
          color: #041a1f;
          margin-right: 12px;
          box-shadow: 0 6px 18px rgba(11,36,84,0.5);
        }
        h1 {
          font-size: 20px;
          margin: 0;
        }
        p.sub {
          color: #9aa4b2;
          font-size: 13px;
          margin-top: 4px;
        }
        .card {
          background: rgba(255,255,255,0.02);
          border: 1px solid rgba(255,255,255,0.04);
          border-radius: 12px;
          padding: 20px;
          margin-bottom: 20px;
          box-shadow: 0 4px 14px rgba(0,0,0,0.4);
        }
        label {
          display: block;
          font-size: 14px;
          margin-bottom: 8px;
          color: #b8c0d0;
        }
        input, select {
          width: 100%;
          padding: 10px;
          border-radius: 8px;
          border: 1px solid rgba(255,255,255,0.08);
          background: transparent;
          color: #e6eef6;
          font-size: 14px;
          margin-bottom: 10px;
        }
        .actions {
          display: flex;
          align-items: center;
          gap: 10px;
        }
        button {
          padding: 10px 16px;
          border-radius: 8px;
          font-weight: 600;
          cursor: pointer;
          border: none;
        }
        #callBtn {
          background: linear-gradient(90deg, #60a5fa, #0ea5a4);
          color: #041a1f;
        }
        #refreshBtn {
          background: transparent;
          color: #9aa4b2;
          border: 1px solid rgba(255,255,255,0.05);
        }
        #uploadBtn {
          background: linear-gradient(90deg,#7c3aed,#60a5fa);
          color: #041a1f;
        }
        .status {
          display: flex;
          gap: 10px;
          margin-top: 10px;
        }
        .badge {
          background: rgba(255,255,255,0.05);
          border-radius: 999px;
          padding: 6px 12px;
          font-size: 12px;
          color: #9aa4b2;
        }
        table {
          width: 100%;
          border-collapse: collapse;
          margin-top: 10px;
        }
        th, td {
          padding: 10px;
          border-bottom: 1px solid rgba(255,255,255,0.05);
          text-align: left;
        }
        th {
          color: #9aa4b2;
          font-size: 13px;
        }
        td {
          font-size: 14px;
        }
        .pill {
          display: inline-block;
          padding: 4px 10px;
          border-radius: 999px;
          font-size: 12px;
          font-weight: 600;
        }
        .status-queued { background: rgba(128,128,128,0.2); color: #9aa4b2; }
        .status-completed { background: rgba(34,197,94,0.2); color: #22c55e; }
        .status-no-answer { background: rgba(239,68,68,0.2); color: #ef4444; }
        .status-failed { background: rgba(239,68,68,0.2); color: #ef4444; }
        .queue-list { max-height: 200px; overflow: auto; border: 1px dashed rgba(255,255,255,0.03); padding: 8px; border-radius: 8px; }
        .muted { color: #9aa4b2 }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="header">
          <div class="brand">
            <div class="logo">TW</div>
            <div>
              <h1>Twilio Call Interface</h1>
              <p class="sub">Place test calls, upload CSVs of numbers and run a queued calling session.</p>
            </div>
          </div>

          <!-- 📰 Blog Navigation Button -->
          <button id="blogBtn"
            style="background:linear-gradient(90deg,#60a5fa,#0ea5a4);
                   color:#041a1f;
                   font-weight:600;
                   border:none;
                   border-radius:8px;
                   padding:10px 14px;
                   cursor:pointer;
                   box-shadow:0 4px 12px rgba(12,55,95,0.4);
                   margin-left:auto;">
            📰 Open Blog
          </button>
        </div>

        <!-- Single call card -->
        <div class="card">
          <label>Destination number (E.164)</label>
          <input id="to" type="text" placeholder="+91..." />
          <div class="actions">
            <button id="callBtn">📞 Make Call</button>
            <button id="refreshBtn">⟳ Refresh</button>
            <span style="margin-left:auto;font-size:13px;color:#9aa4b2;">From: <span id="fromNumber">loading...</span></span>
          </div>
          <div class="status">
            <span id="status" class="badge">Ready</span>
            <span class="badge">Polling: active</span>
          </div>
        </div>

        <!-- CSV upload & queue controls -->
        <div class="card">
          <label>Upload CSV (first column or header "number")</label>
          <input id="csvfile" type="file" accept=".csv" />
          <div class="actions" style="align-items:center;">
            <button id="uploadBtn">⬆️ Upload</button>
            <button id="startQueueBtn" style="background:linear-gradient(90deg,#10b981,#06b6d4); color:#041a1f;">▶ Start Queue</button>
            <button id="pauseQueueBtn" style="background:transparent; color:#9aa4b2; border:1px solid rgba(255,255,255,0.05);">⏸ Pause</button>
            <button id="clearQueueBtn" style="background:transparent; color:#f97316; border:1px solid rgba(255,255,255,0.05);">✖ Clear</button>
            <span style="margin-left:auto;font-size:13px;color:#9aa4b2;">Queued: <span id="queuedCount">0</span></span>
          </div>

          <div style="margin-top:10px;">
            <div class="muted" style="font-size:13px;">Preview (first 200 numbers):</div>
            <div id="queuePreview" class="queue-list muted">No numbers uploaded</div>
          </div>
        </div>

        <!-- Recent calls / search -->
        <div class="card">
          <label>Search recent calls</label>
          <input id="search" type="text" placeholder="Search by number or SID..." />
          <table>
            <thead>
              <tr>
                <th>To</th>
                <th>Status</th>
                <th>Started</th>
              </tr>
            </thead>
            <tbody id="logs">
              <tr><td colspan="3" style="color:#9aa4b2;">Loading recent calls…</td></tr>
            </tbody>
          </table>
        </div>
      </div>

      <script>
        // DOM refs
        const logs = document.getElementById('logs');
        const search = document.getElementById('search');
        const statusEl = document.getElementById('status');
        const fromNumberEl = document.getElementById('fromNumber');
        const toInput = document.getElementById('to');

        // Queue UI
        const csvfile = document.getElementById('csvfile');
        const uploadBtn = document.getElementById('uploadBtn');
        const queuePreview = document.getElementById('queuePreview');
        const queuedCount = document.getElementById('queuedCount');
        const startQueueBtn = document.getElementById('startQueueBtn');
        const pauseQueueBtn = document.getElementById('pauseQueueBtn');
        const clearQueueBtn = document.getElementById('clearQueueBtn');

        // In-memory queue in the browser
        let QUEUE = [];
        let queueRunning = false;
        let queuePaused = false;
        let currentQueueIndex = 0;

        // --- fetching & rendering recent calls ---
        async function fetchRecent() {
          try {
            const res = await fetch('/api/calls');
            const data = await res.json();
            if (Array.isArray(data)) {
              renderLogs(data);
              if (data.length && data[0].from) fromNumberEl.textContent = data[0].from;
            } else if (data && data.error) {
              logs.innerHTML = '<tr><td colspan="3" style="color:#9aa4b2;">Error: ' + data.error + '</td></tr>';
            } else {
              logs.innerHTML = '<tr><td colspan="3" style="color:#9aa4b2;">No calls</td></tr>';
            }
          } catch (e) {
            console.error('fetchRecent error', e);
            logs.innerHTML = '<tr><td colspan="3" style="color:#9aa4b2;">Failed to load calls</td></tr>';
          }
        }

        function renderLogs(data) {
          const q = (search.value || '').toLowerCase();
          logs.innerHTML = '';
          // Sort by start_time desc if present, else leave order
          try {
            data.sort((a,b) => {
              const ta = a.start_time ? new Date(a.start_time).getTime() : 0;
              const tb = b.start_time ? new Date(b.start_time).getTime() : 0;
              return tb - ta;
            });
          } catch(e){/* ignore */ }

          const filtered = (data || []).filter(c => {
            if (!c) return false;
            const to = (c.to || '').toString().toLowerCase();
            const sid = (c.sid || '').toString().toLowerCase();
            return !q || to.includes(q) || sid.includes(q);
          });
          if (filtered.length === 0) {
            logs.innerHTML = '<tr><td colspan="3" style="color:#9aa4b2;">No calls found</td></tr>';
            return;
          }
          filtered.forEach(c => {
            const tr = document.createElement('tr');
            const statusClass = (c.status || '').toLowerCase().replace(/\s+/g, '-');
            tr.innerHTML = `
              <td>${c.to || '—'}<div style="font-size:12px;color:#9aa4b2;">${c.from || ''}</div></td>
              <td><span class="pill status-${statusClass}">${(c.status || 'UNKNOWN').toUpperCase()}</span></td>
              <td style="color:#9aa4b2;font-size:13px;">${c.start_time || 'N/A'}</td>
            `;
            logs.appendChild(tr);
          });
        }

        // --- single call (existing flow) ---
        async function makeCall() {
          const to = toInput.value.trim();
          if (!to) { alert('Enter destination number'); return; }
          await makeCallTo(to);
        }

        // new helper that uses existing /api/call and polls /api/status/:sid just like original
        async function makeCallTo(to) {
          statusEl.textContent = 'Calling ' + to + '...';
          try {
            const res = await fetch('/api/call', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ to })
            });
            const resp = await res.json();
            if (resp.error) {
              statusEl.textContent = 'Error: ' + resp.error;
              return { error: resp.error };
            }
            const sid = resp.sid;
            statusEl.textContent = 'Call created. SID: ' + sid + ' (polling status)';
            const terminal = ['completed','failed','busy','no-answer','canceled'];
            let done = false;
            while (!done) {
              await new Promise(r => setTimeout(r, 1500));
              const sres = await fetch('/api/status/' + sid);
              const sjson = await sres.json();
              const st = sjson.status || sjson.CallStatus || 'unknown';
              statusEl.textContent = 'SID: ' + sid + ' | Status: ' + st;
              // refresh call logs so UI updates quickly
              await fetchRecent();
              if (terminal.includes(st)) {
                done = true;
                statusEl.textContent += ' (finished)';
                // final refresh
                await fetchRecent();
                return { sid, status: st };
              }
              // allow queue pause/stop to interrupt
              if (queuePaused || !queueRunning) {
                statusEl.textContent += ' (paused/stopped)';
                return { sid, status: st, paused: true };
              }
            }
          } catch (e) {
            console.error('makeCallTo error', e);
            statusEl.textContent = 'Error creating call';
            return { error: e.message };
          } finally {
            await fetchRecent();
          }
        }

        // --- CSV upload to extract numbers ---
        uploadBtn.addEventListener('click', async () => {
          const file = csvfile.files[0];
          if (!file) { alert('Select a CSV file'); return; }
          const form = new FormData();
          form.append('file', file);
          uploadBtn.textContent = 'Uploading...';
          uploadBtn.disabled = true;
          try {
            const res = await fetch('/api/upload', {
              method: 'POST',
              body: form
            });
            const json = await res.json();
            if (json.error) {
              alert('Upload error: ' + json.error);
            } else {
              // json.numbers = array of numbers
              QUEUE = json.numbers || [];
              currentQueueIndex = 0;
              renderQueuePreview();
              alert('Uploaded ' + QUEUE.length + ' numbers. Click "Start Queue" to begin.');
            }
          } catch (e) {
            console.error('upload error', e);
            alert('Upload failed: ' + e.message);
          } finally {
            uploadBtn.disabled = false;
            uploadBtn.textContent = '⬆️ Upload';
          }
        });

        function renderQueuePreview() {
          queuedCount.textContent = QUEUE.length - currentQueueIndex;
          if (QUEUE.length === 0 || currentQueueIndex >= QUEUE.length) {
            queuePreview.innerHTML = '<div class="muted">No numbers uploaded</div>';
            return;
          }
          // show preview of up to 200 numbers
          const preview = QUEUE.slice(currentQueueIndex, currentQueueIndex + 200)
            .map((n,i) => `<div>${currentQueueIndex + i + 1}. ${n}</div>`)
            .join('');
          queuePreview.innerHTML = preview;
        }

        // Start Queue: iterative client-side runner that POSTS to existing /api/call
        startQueueBtn.addEventListener('click', async () => {
          if (!QUEUE || QUEUE.length === 0 || currentQueueIndex >= QUEUE.length) {
            alert('Queue is empty. Upload a CSV first.');
            return;
          }
          if (queueRunning && !queuePaused) {
            alert('Queue already running');
            return;
          }
          queuePaused = false;
          queueRunning = true;
          startQueueBtn.disabled = true;
          pauseQueueBtn.disabled = false;
          clearQueueBtn.disabled = true;

          while (queueRunning && currentQueueIndex < QUEUE.length) {
            if (queuePaused) break;
            const number = QUEUE[currentQueueIndex];
            // set the single-call input so user can see it
            toInput.value = number;
            // call and wait for it to finish (this uses your existing server call flow)
            const result = await makeCallTo(number);
            // If paused flag returned, break out to let user resume
            if (result && result.paused) break;
            // advance index (even if error to avoid infinite loop)
            currentQueueIndex += 1;
            renderQueuePreview();
            // small delay between calls to avoid bursts (optional)
            await new Promise(r => setTimeout(r, 700));
          }

          queueRunning = !queuePaused && currentQueueIndex < QUEUE.length;
          startQueueBtn.disabled = false;
          pauseQueueBtn.disabled = false;
          clearQueueBtn.disabled = false;
        });

        pauseQueueBtn.addEventListener('click', () => {
          if (!queueRunning) { alert('Queue is not running'); return; }
          queuePaused = true;
          queueRunning = false;
          pauseQueueBtn.disabled = true;
          startQueueBtn.disabled = false;
          statusEl.textContent = 'Queue paused';
        });

        clearQueueBtn.addEventListener('click', () => {
          if (queueRunning) {
            if (!confirm('Queue is running. Pause it first?')) return;
          }
          QUEUE = [];
          currentQueueIndex = 0;
          queuePaused = false;
          queueRunning = false;
          renderQueuePreview();
        });

        // Wire single call + refresh + search
        document.getElementById('callBtn').addEventListener('click', makeCall);
        document.getElementById('refreshBtn').addEventListener('click', fetchRecent);
        search.addEventListener('input', fetchRecent);

        // initial fetch and polling
        fetchRecent();
        setInterval(fetchRecent, 10000);
      </script>
      <script>
        document.getElementById('blogBtn').addEventListener('click', () => {
          window.location.href = '/blog';
        });
      </script>
    </body>
  </html>
  HTML
end

# --- New endpoint: handle CSV upload (returns parsed numbers) ---
post '/api/upload' do
  begin
    unless params[:file] && (tempfile = params[:file][:tempfile])
      status 400
      return { error: 'missing file' }.to_json
    end
    raw = tempfile.read
    numbers = []

    # Try CSV parse with headers - look for "number" header (case-insensitive).
    begin
      csv = CSV.parse(raw, headers: true)
      if csv.headers && csv.headers.any?
        # find a header that looks like number / phone
        num_header = csv.headers.find { |h| h && h.to_s.strip.downcase.include?('number') } || csv.headers.first
        csv.each do |row|
          v = row[num_header]
          next if v.nil?
          v = v.to_s.strip
          numbers << v unless v == ''
        end
      else
        # if headers but empty, fallback to parsing with no headers
        raise
      end
    rescue => _
      # fallback to no-headers parse: use first column
      CSV.parse(raw, headers: false).each do |row|
        next if row.nil? || row[0].nil?
        v = row[0].to_s.strip
        numbers << v unless v == ''
      end
    end

    # normalize: remove duplicates, keep order
    seen = {}
    numbers = numbers.select { |n| n && n.length > 0 && (seen[n] ? false : (seen[n] = true)) }

    { numbers: numbers }.to_json
  rescue => e
    status 500
    { error: e.message }.to_json
  end
end

# --- API routes below remain unchanged (preserved logic) ---

post '/api/call' do
  req = JSON.parse(request.body.read)
  to = req['to']
  halt 400, { error: 'missing to number' }.to_json unless to

  begin
    client = twilio_client
    status_callback_url = "#{request.base_url}/status_callback"
    call = client.calls.create(
      from: from_number,
      to: to,
      url: 'http://demo.twilio.com/docs/voice.xml',
      status_callback: status_callback_url,
      status_callback_method: 'POST',
      status_callback_event: ['initiated','ringing','answered','completed']
    )
    CALLS[call.sid] = { sid: call.sid, to: call.to, from: call.from, status: call.status, start_time: call.start_time }
    { sid: call.sid }.to_json
  rescue => e
    status 500
    { error: e.message }.to_json
  end
end

post '/status_callback' do
  sid = params['CallSid']
  CALLS[sid] ||= {}
  CALLS[sid].merge!({
    sid: sid,
    to: params['To'],
    from: params['From'],
    status: params['CallStatus'],
    duration: params['CallDuration'],
    timestamp: Time.now.to_s
  })
  content_type 'text/plain'
  "OK"
end

get '/api/status/:sid' do
  sid = params[:sid]
  if CALLS.key?(sid)
    CALLS[sid].to_json
  else
    begin
      call = twilio_client.calls(sid).fetch
      { sid: call.sid, to: call.to, from: call.from, status: call.status, start_time: call.start_time }.to_json
    rescue => e
      status 404
      { error: 'not found', detail: e.message }.to_json
    end
  end
end

get '/api/calls' do
  begin
    recent = twilio_client.calls.list(limit: 20).map do |c|
      { sid: c.sid, to: c.to, from: c.from, status: c.status, start_time: c.start_time }
    end
    recent.each do |r|
      if CALLS.key?(r[:sid])
        r[:status] = CALLS[r[:sid]][:status]
      end
    end
    recent.to_json
  rescue => e
    status 500
    { error: e.message }.to_json
  end
end
