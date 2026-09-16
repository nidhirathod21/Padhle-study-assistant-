(function () {
  var sampleFn = null;
  var downloadsCap = null;
  var sampleReady = false;
  var downloadsReady = false;

  var EXAM_TYPES = [
    { id: 'general', label: 'General study' },
    { id: 'board', label: 'Board exam' },
    { id: 'jee', label: 'JEE' },
    { id: 'neet', label: 'NEET' },
    { id: 'upsc', label: 'UPSC' },
    { id: 'banking', label: 'Banking' },
    { id: 'viva', label: 'College viva' }
  ];

  var EXAM_INSTRUCTIONS = {
    general: 'Write a well-rounded, general-purpose study aid.',
    board: 'Match Indian school board exam style: frame things the way 2, 5, and 10-mark answers are usually written, and keep MCQs at NCERT level.',
    jee: 'Make MCQs sharp and concept-application heavy, JEE style, with plausible tricky distractors.',
    neet: 'Make MCQs NEET style — factual, precise, NCERT-level detail across biology, chemistry or physics as relevant.',
    upsc: 'Mix UPSC Prelims-style objective MCQs with a couple of Mains-style analytical points worked into the summary.',
    banking: 'Make MCQs banking-exam style: quick, fact-based, moderately tricky, testing speed as much as depth.',
    viva: 'Lean into conceptual why/how questions with spoken-style model answers, and add a short follow-up cross-question to a couple of them, the way a viva examiner would.'
  };

  var LANGUAGES = [
    { id: 'english', label: 'English' },
    { id: 'hindi', label: 'Hindi' },
    { id: 'hinglish', label: 'Hinglish' }
  ];

  var LANGUAGE_INSTRUCTIONS = {
    english: 'Write everything in clear, plain English.',
    hindi: 'Write everything primarily in Hindi, in Devanagari script. Where a technical term reads better in English, keep it in English in brackets.',
    hinglish: 'Write in natural Hinglish — the way Indian students actually talk, mixing Hindi and English within the same sentences. Keep technical or scientific terms in English.'
  };

  var state = {
    notes: '',
    examType: 'general',
    language: 'english',
    simplify: false,
    want: { summary: true, keyPoints: true, mcqs: true, viva: true },
    loading: false,
    error: null,
    results: null,
    activeTab: 'summary',
    quiz: null,
    reviewMode: false,
    vivaOpen: {},
    exportNote: null,
    fileLoading: false,
    fileStatus: null,
    fileStatusError: false
  };

  var MAX_FILE_BYTES = 30 * 1024 * 1024; // 30MB, matches PRD's 20-50MB guidance
  var pdfWorkerReady = false;

  function el(tag, attrs, children) {
    var node = document.createElement(tag);
    attrs = attrs || {};
    for (var k in attrs) {
      if (k === 'text') node.textContent = attrs[k];
      else if (k.indexOf('on') === 0 && typeof attrs[k] === 'function') node.addEventListener(k.slice(2), attrs[k]);
      else if (k === 'html') node.innerHTML = attrs[k];
      else node.setAttribute(k, attrs[k]);
    }
    (children || []).forEach(function (c) { if (c) node.appendChild(c); });
    return node;
  }

  function checkSvg() {
    return '<svg viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M3 8.5L6.2 11.5L13 4.5" stroke="' + getComputedStyle(document.documentElement).getPropertyValue('--paper') + '" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  }

  function buildPrompt() {
    var sections = [];
    if (state.want.summary) sections.push('summary');
    if (state.want.keyPoints) sections.push('keyPoints');
    if (state.want.mcqs) sections.push('mcqs');
    if (state.want.viva) sections.push('viva');

    var shapeLines = [];
    if (state.want.summary) shapeLines.push('  "summary": "a clear 3-5 sentence summary as one string"');
    if (state.want.keyPoints) shapeLines.push('  "keyPoints": ["5 to 7 short bullet point strings"]');
    if (state.want.mcqs) shapeLines.push('  "mcqs": [{"question":"string","options":["4 option strings"],"correctIndex":0,"explanation":"short string explaining the right answer"}]  // exactly 5 items');
    if (state.want.viva) shapeLines.push('  "viva": [{"question":"string","answer":"a model spoken answer, 2-4 sentences"}]  // exactly 5 items');

    var lines = [];
    lines.push('You are helping a student in India study from their own notes. Respond with ONLY a single JSON object, no preamble, no markdown fences, matching exactly this shape:');
    lines.push('{');
    lines.push(shapeLines.join(',\n'));
    lines.push('}');
    lines.push('Only include the keys listed above, in that shape.');
    lines.push('');
    lines.push('Exam type: ' + state.examType + '. ' + EXAM_INSTRUCTIONS[state.examType]);
    lines.push('Language: ' + LANGUAGE_INSTRUCTIONS[state.language]);
    if (state.simplify) {
      lines.push('Also simplify the language: use short sentences and everyday words. The first time a technical term appears, briefly explain it in simple words without dropping the term itself.');
    }
    lines.push('Ground everything strictly in the study material below. Do not invent facts, numbers or names that are not in it or a reasonable, well-known extension of it.');
    lines.push('');
    lines.push('Study material:');
    lines.push('"""');
    lines.push(state.notes);
    lines.push('"""');
    return lines.join('\n');
  }

  function normalizeResults(data) {
    var r = {};
    if (state.want.summary) r.summary = typeof data.summary === 'string' ? data.summary : '';
    if (state.want.keyPoints) r.keyPoints = Array.isArray(data.keyPoints) ? data.keyPoints.filter(function(x){return typeof x === 'string';}) : [];
    if (state.want.mcqs) {
      r.mcqs = Array.isArray(data.mcqs) ? data.mcqs.filter(function (q) {
        return q && typeof q.question === 'string' && Array.isArray(q.options) && q.options.length >= 2 && typeof q.correctIndex === 'number';
      }) : [];
    }
    if (state.want.viva) {
      r.viva = Array.isArray(data.viva) ? data.viva.filter(function (q) {
        return q && typeof q.question === 'string' && typeof q.answer === 'string';
      }) : [];
    }
    return r;
  }

  function cleanText(text) {
    return (text || '').replace(/\s+/g, ' ').trim();
  }

  function sentenceSplit(text) {
    return cleanText(text).split(/(?<=[.!?])\s+|\n+/).filter(function (part) { return part && part.trim().length > 0; }).slice(0, 12);
  }

  function uniq(items) {
    return items.filter(function (item, idx) { return item && item.trim() && items.indexOf(item) === idx; });
  }

  function pickKeyConcepts(text) {
    var words = cleanText(text).toLowerCase().replace(/[^a-z0-9\s]/g, ' ').split(/\s+/);
    var stop = ['the','a','an','and','or','but','if','then','for','with','from','into','that','this','these','those','is','are','was','were','be','been','being','of','in','on','at','to','as','by','it','its','their','they','them','his','her','he','she','we','you','i','your','our','also','about','have','has','had','more','most','than','not','can','could','should','would','may','might','one','two','three','four','five','six','seven','eight','nine','ten','what','which','when','where','how','why','who'];
    var counts = {};
    words.forEach(function (word) {
      if (word.length < 4 || stop.indexOf(word) !== -1) return;
      counts[word] = (counts[word] || 0) + 1;
    });
    var ordered = Object.keys(counts).sort(function (a, b) { return counts[b] - counts[a]; }).slice(0, 8);
    return ordered.length ? ordered : ['topic', 'concept', 'idea', 'method', 'example', 'summary'];
  }

  function buildFallbackStudyPack() {
    var rawText = state.notes || '';
    var sentences = sentenceSplit(rawText);
    if (!sentences.length) {
      return {
        summary: 'No study material was provided yet. Paste notes, chapter text, or a PDF excerpt and generate again.',
        keyPoints: ['Add study material to begin.'],
        mcqs: [{
          question: 'What should you do before generating a study pack?',
          options: ['Paste or upload notes', 'Skip the material', 'Delete the page', 'Ignore the chapter'],
          correctIndex: 0,
          explanation: 'The app needs actual study material to create a useful summary, MCQs, and viva questions.'
        }],
        viva: [{
          question: 'Why is it important to provide your notes before generating a study pack?',
          answer: 'The notes are the source material for the summary and questions. Without them, there is no content to study or review.'
        }]
      };
    }

    var summaryText = sentences.slice(0, Math.min(4, sentences.length)).join(' ');
    var examBias = EXAM_INSTRUCTIONS[state.examType] || EXAM_INSTRUCTIONS.general;
    var summary = summaryText + ' ' + examBias;

    var concepts = pickKeyConcepts(rawText);
    var keyPoints = uniq(sentences.map(function (sentence, idx) {
      var concept = concepts[idx % concepts.length];
      return concept ? concept.charAt(0).toUpperCase() + concept.slice(1) + ': ' + sentence : sentence;
    })).slice(0, 6);

    var mcqs = [];
    for (var i = 0; i < 5; i++) {
      var baseSentence = sentences[i % sentences.length] || sentences[0];
      var otherSentence = sentences[(i + 1) % sentences.length] || sentences[0];
      var altSentence = sentences[(i + 2) % sentences.length] || sentences[0];
      var question = 'Which statement matches the study notes most closely?';
      var options = [baseSentence, otherSentence, altSentence, 'The notes do not provide enough information to decide.'];
      mcqs.push({
        question: question,
        options: options,
        correctIndex: 0,
        explanation: 'This option reflects the material in the notes and is the closest match to the topic described.'
      });
    }

    var viva = [];
    for (var j = 0; j < 5; j++) {
      var concept = concepts[j % concepts.length];
      var item = {
        question: 'Explain the importance of ' + concept + ' in this topic.',
        answer: 'The notes indicate that ' + concept + ' is a central idea in the topic. It supports the main explanation, helps connect ideas, and gives a clear way to understand the material.'
      };
      viva.push(item);
    }

    return { summary: summary, keyPoints: keyPoints, mcqs: mcqs, viva: viva };
  }

  function firstTab() {
    if (state.want.summary) return 'summary';
    if (state.want.keyPoints) return 'keyPoints';
    if (state.want.mcqs) return 'mcqs';
    if (state.want.viva) return 'viva';
    return 'summary';
  }

  function mapError(code) {
    switch (code) {
      case 'not_granted': return 'This page needs permission to use Claude. Allow it, then try again.';
      case 'rate_limited': return 'Too many requests right now — wait a few seconds and try again.';
      case 'refused': return 'That content could not be processed. Try a different excerpt.';
      case 'prompt_too_large': return 'That is a lot of text for one go — try pasting a shorter section.';
      case 'sampling_disabled': return 'Claude is not available on this account right now.';
      case 'empty_completion': return 'No study pack came back — try again, or with a shorter excerpt.';
      case 'invalid_json': return 'The response could not be read — try generating again.';
      case 'cancelled': return null;
      default: return 'Something went wrong generating your study pack. Try again in a moment.';
    }
  }

  async function generate() {
    if (!state.notes.trim()) { state.error = 'Paste some notes or text first.'; render(); return; }
    if (!Object.values(state.want).some(Boolean)) { state.error = 'Pick at least one thing to generate.'; render(); return; }

    state.loading = true;
    state.error = null;
    render();
    try {
      var data;
      if (!sampleFn) {
        data = buildFallbackStudyPack();
      } else {
        var prompt = buildPrompt();
        data = await sampleFn.json(prompt, { modelTier: 'default' });
      }
      state.results = normalizeResults(data);
      state.activeTab = firstTab();
      state.quiz = null;
      state.reviewMode = false;
      state.vivaOpen = {};
    } catch (e) {
      var msg = mapError(e && e.code);
      if (msg) state.error = msg;
      else state.error = 'Something went wrong generating your study pack. Try again in a moment.';
    } finally {
      state.loading = false;
      render();
    }
  }

  function startQuiz() {
    state.quiz = { index: 0, score: 0, selected: null, answered: false, finished: false };
    state.reviewMode = false;
    render();
  }

  function answerQuiz(optionIndex) {
    var q = state.results.mcqs[state.quiz.index];
    state.quiz.selected = optionIndex;
    state.quiz.answered = true;
    if (optionIndex === q.correctIndex) state.quiz.score += 1;
    render();
  }

  function nextQuiz() {
    if (state.quiz.index + 1 >= state.results.mcqs.length) {
      state.quiz.finished = true;
    } else {
      state.quiz.index += 1;
      state.quiz.selected = null;
      state.quiz.answered = false;
    }
    render();
  }

  function buildExportText() {
    var lines = ['Padhle — Study Pack', ''];
    if (state.results.summary) { lines.push('SUMMARY', state.results.summary, ''); }
    if (state.results.keyPoints && state.results.keyPoints.length) {
      lines.push('KEY POINTS');
      state.results.keyPoints.forEach(function (p) { lines.push('- ' + p); });
      lines.push('');
    }
    if (state.results.mcqs && state.results.mcqs.length) {
      lines.push('MCQs');
      state.results.mcqs.forEach(function (q, i) {
        lines.push((i + 1) + '. ' + q.question);
        q.options.forEach(function (opt, oi) {
          lines.push('   ' + String.fromCharCode(97 + oi) + ') ' + opt + (oi === q.correctIndex ? '  [correct]' : ''));
        });
        if (q.explanation) lines.push('   Why: ' + q.explanation);
        lines.push('');
      });
    }
    if (state.results.viva && state.results.viva.length) {
      lines.push('VIVA QUESTIONS');
      state.results.viva.forEach(function (q, i) {
        lines.push((i + 1) + '. ' + q.question);
        lines.push('   Model answer: ' + q.answer);
        lines.push('');
      });
    }
    lines.push('Generated with Padhle — always cross-check against your textbook before an exam.');
    return lines.join('\n');
  }

  async function exportPack() {
    if (!downloadsCap) return;
    try {
      await downloadsCap.save({ filename: 'padhle-study-pack.txt', data: buildExportText() });
      state.exportNote = 'Saved.';
    } catch (e) {
      if (e && e.code === 'declined') state.exportNote = null;
      else state.exportNote = 'Could not save the file — try again.';
    }
    render();
  }

  function ensurePdfWorker() {
    if (pdfWorkerReady) return true;
    if (typeof pdfjsLib === 'undefined') return false;
    pdfjsLib.GlobalWorkerOptions.workerSrc = 'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.worker.min.js';
    pdfWorkerReady = true;
    return true;
  }

  async function extractPdfText(file) {
    var buf = await file.arrayBuffer();
    var doc = await pdfjsLib.getDocument({ data: buf }).promise;
    var pages = [];
    for (var i = 1; i <= doc.numPages; i++) {
      var page = await doc.getPage(i);
      var content = await page.getTextContent();
      var text = content.items.map(function (it) { return it.str; }).join(' ');
      pages.push(text);
    }
    return pages.join('\n\n');
  }

  async function handleFile(file) {
    if (!file) return;
    var name = file.name || '';
    var lower = name.toLowerCase();
    var isPdf = lower.endsWith('.pdf');
    var isText = lower.endsWith('.txt') || lower.endsWith('.md');

    if (!isPdf && !isText) {
      state.fileStatus = 'Only PDF and text (.txt, .md) files are supported right now.';
      state.fileStatusError = true;
      render();
      return;
    }
    if (file.size > MAX_FILE_BYTES) {
      state.fileStatus = 'That file is over 30MB — try a smaller file or paste the text directly.';
      state.fileStatusError = true;
      render();
      return;
    }

    state.fileLoading = true;
    state.fileStatus = isPdf ? 'Reading your PDF…' : 'Reading your file…';
    state.fileStatusError = false;
    render();

    try {
      if (isText) {
        var text = await file.text();
        state.notes = (state.notes ? state.notes + '\n\n' : '') + text;
        state.fileStatus = 'Added text from ' + name + '.';
      } else {
        if (!ensurePdfWorker()) {
          state.fileStatus = 'PDF reading is not available right now — try pasting the text instead.';
          state.fileStatusError = true;
          state.fileLoading = false;
          render();
          return;
        }
        var pdfText = await extractPdfText(file);
        if (!pdfText.trim()) {
          state.fileStatus = 'Could not find readable text in that PDF — it may be a scan. Try pasting the text instead.';
          state.fileStatusError = true;
        } else {
          state.notes = (state.notes ? state.notes + '\n\n' : '') + pdfText;
          state.fileStatus = 'Added text from ' + name + '.';
        }
      }
    } catch (e) {
      state.fileStatus = 'Could not read that file — try pasting the text instead.';
      state.fileStatusError = true;
    } finally {
      state.fileLoading = false;
      render();
    }
  }

  // ---------- render ----------

  function render() {
    var app = document.getElementById('app');
    app.innerHTML = '';

    var header = el('header', { class: 'brand' }, [
      el('span', { class: 'mark', text: '✏️' }),
      el('h1', { text: 'Padhle' })
    ]);
    app.appendChild(header);
    app.appendChild(el('p', { class: 'tagline', text: 'Paste your notes, chapter, or slide text. Get a summary, key points, MCQs and viva questions back — in English, Hindi or Hinglish.' }));

    // Input block
    var inputBlock = el('section', { class: 'block' });
    inputBlock.appendChild(el('label', { class: 'label', for: 'notes', text: 'What are we studying today?' }));
    var textarea = el('textarea', {
      id: 'notes',
      placeholder: 'Paste your chapter, notes, or slide text here…',
      oninput: function (e) { state.notes = e.target.value; }
    });
    textarea.value = state.notes;
    inputBlock.appendChild(textarea);

    var fileInput = el('input', {
      type: 'file',
      accept: '.pdf,.txt,.md',
      style: 'display:none;',
      onchange: function (e) { var f = e.target.files && e.target.files[0]; handleFile(f); e.target.value = ''; }
    });

    var dropzone = el('div', {
      class: 'dropzone',
      tabindex: '0',
      role: 'button',
      'aria-label': 'Upload a PDF or text file',
      onclick: function () { fileInput.click(); },
      onkeydown: function (e) { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); fileInput.click(); } },
      ondragover: function (e) { e.preventDefault(); dropzone.classList.add('dragover'); },
      ondragleave: function () { dropzone.classList.remove('dragover'); },
      ondrop: function (e) {
        e.preventDefault();
        dropzone.classList.remove('dragover');
        var f = e.dataTransfer.files && e.dataTransfer.files[0];
        handleFile(f);
      }
    }, [
      el('span', { class: 'dropzone-text', html: '<strong>Drag a PDF or text file here</strong>, or click to upload' }),
      el('span', { class: 'btn-ghost', text: state.fileLoading ? 'Reading…' : 'Choose file' })
    ]);
    dropzone.appendChild(fileInput);

    inputBlock.appendChild(dropzone);
    if (state.fileStatus) {
      inputBlock.appendChild(el('div', { class: 'file-status' + (state.fileStatusError ? ' error' : ''), text: state.fileStatus }));
    }
    app.appendChild(inputBlock);

    // Exam type
    var examBlock = el('section', { class: 'block' });
    examBlock.appendChild(el('span', { class: 'label', text: 'Which exam is this for?' }));
    var examRow = el('div', { class: 'chiprow' });
    EXAM_TYPES.forEach(function (ex) {
      examRow.appendChild(el('button', {
        class: 'chip',
        type: 'button',
        'aria-pressed': String(state.examType === ex.id),
        text: ex.label,
        onclick: function () { state.examType = ex.id; render(); }
      }));
    });
    examBlock.appendChild(examRow);
    app.appendChild(examBlock);

    // Language + simplify
    var langBlock = el('section', { class: 'block' });
    var rowSplit = el('div', { class: 'row-split' });

    var langCol = el('div');
    langCol.appendChild(el('span', { class: 'label', text: 'Explain it in' }));
    var seg = el('div', { class: 'segmented' });
    LANGUAGES.forEach(function (l) {
      seg.appendChild(el('button', {
        type: 'button',
        'aria-pressed': String(state.language === l.id),
        text: l.label,
        onclick: function () { state.language = l.id; render(); }
      }));
    });
    langCol.appendChild(seg);
    rowSplit.appendChild(langCol);

    var simpCol = el('div');
    simpCol.appendChild(el('span', { class: 'label', text: 'Simplify the language' }));
    var switchRow = el('div', { class: 'switch-row' });
    var sw = el('button', {
      class: 'switch',
      type: 'button',
      role: 'switch',
      'aria-checked': String(state.simplify),
      onclick: function () { state.simplify = !state.simplify; render(); }
    }, [el('span', { class: 'knob' })]);
    switchRow.appendChild(sw);
    switchRow.appendChild(el('span', { class: 'switch-label', text: state.simplify ? 'On — easier words' : 'Off — normal level' }));
    simpCol.appendChild(switchRow);
    rowSplit.appendChild(simpCol);

    langBlock.appendChild(rowSplit);
    app.appendChild(langBlock);

    // Outputs
    var outBlock = el('section', { class: 'block' });
    outBlock.appendChild(el('span', { class: 'label', text: 'What do you need?' }));
    var grid = el('div', { class: 'check-grid' });
    var outputDefs = [
      { key: 'summary', label: 'Summary' },
      { key: 'keyPoints', label: 'Key points' },
      { key: 'mcqs', label: 'MCQs' },
      { key: 'viva', label: 'Viva questions' }
    ];
    outputDefs.forEach(function (o) {
      var item = el('div', {
        class: 'check-item',
        role: 'checkbox',
        tabindex: '0',
        'aria-checked': String(state.want[o.key]),
        onclick: function () { state.want[o.key] = !state.want[o.key]; render(); },
        onkeydown: function (e) { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); state.want[o.key] = !state.want[o.key]; render(); } }
      });
      item.appendChild(el('span', { class: 'check-box', html: checkSvg() }));
      item.appendChild(el('span', { text: o.label }));
      grid.appendChild(item);
    });
    outBlock.appendChild(grid);
    app.appendChild(outBlock);

    // Generate button
    var genBlock = el('section', { class: 'block' });
    var genBtn = el('button', {
      class: 'generate-btn',
      type: 'button',
      disabled: state.loading ? 'true' : null,
      text: state.loading ? 'Reading through your notes…' : 'Generate study pack',
      onclick: generate
    });
    if (!state.loading) genBtn.removeAttribute('disabled'); else genBtn.setAttribute('disabled', 'true');
    genBlock.appendChild(genBtn);
    if (state.error) {
      genBlock.appendChild(el('div', { class: 'status-line error', text: state.error }));
    } else if (!sampleReady) {
      genBlock.appendChild(el('div', { class: 'status-line', text: 'Checking what this page can do…' }));
    } else if (!sampleFn) {
      genBlock.appendChild(el('div', { class: 'status-line', text: 'Claude not detected — local study pack mode is active.' }));
    }
    app.appendChild(genBlock);

    // Results
    var resultsSection = el('section', { class: 'results' });
    if (!state.results) {
      resultsSection.appendChild(el('div', { class: 'empty-note', text: 'Paste something above and hit generate — your study pack shows up here.' }));
    } else {
      var tabDefs = [];
      if (state.want.summary) tabDefs.push({ key: 'summary', label: 'Summary' });
      if (state.want.keyPoints) tabDefs.push({ key: 'keyPoints', label: 'Key points' });
      if (state.want.mcqs) tabDefs.push({ key: 'mcqs', label: 'MCQs' });
      if (state.want.viva) tabDefs.push({ key: 'viva', label: 'Viva' });

      var tabs = el('div', { class: 'tabs', role: 'tablist' });
      tabDefs.forEach(function (t) {
        tabs.appendChild(el('button', {
          class: 'tab',
          role: 'tab',
          type: 'button',
          'aria-selected': String(state.activeTab === t.key),
          text: t.label,
          onclick: function () { state.activeTab = t.key; render(); }
        }));
      });
      resultsSection.appendChild(tabs);

      var panel = el('div', { class: 'panel' });

      if (state.activeTab === 'summary') {
        var sdiv = el('div', { class: 'summary-text' });
        (state.results.summary || '').split(/\n+/).filter(Boolean).forEach(function (p) {
          sdiv.appendChild(el('p', { text: p }));
        });
        if (!state.results.summary) sdiv.appendChild(el('p', { class: 'empty-note', text: 'No summary came back.' }));
        panel.appendChild(sdiv);
      }

      if (state.activeTab === 'keyPoints') {
        var kul = el('ul', { class: 'keypoints' });
        (state.results.keyPoints || []).forEach(function (p) { kul.appendChild(el('li', { text: p })); });
        if (!state.results.keyPoints || !state.results.keyPoints.length) panel.appendChild(el('div', { class: 'empty-note', text: 'No key points came back.' }));
        else panel.appendChild(kul);
      }

      if (state.activeTab === 'mcqs') {
        panel.appendChild(renderMcqs());
      }

      if (state.activeTab === 'viva') {
        var vivaWrap = el('div');
        (state.results.viva || []).forEach(function (q, i) {
          var item = el('div', { class: 'viva-item' });
          item.appendChild(el('div', { class: 'viva-q', text: (i + 1) + '. ' + q.question }));
          if (state.vivaOpen[i]) {
            item.appendChild(el('div', { class: 'viva-answer', text: q.answer }));
            item.appendChild(el('button', { class: 'viva-reveal', type: 'button', text: 'Hide answer', onclick: function () { state.vivaOpen[i] = false; render(); } }));
          } else {
            item.appendChild(el('button', { class: 'viva-reveal', type: 'button', text: 'Show model answer', onclick: function () { state.vivaOpen[i] = true; render(); } }));
          }
          vivaWrap.appendChild(item);
        });
        if (!state.results.viva || !state.results.viva.length) vivaWrap.appendChild(el('div', { class: 'empty-note', text: 'No viva questions came back.' }));
        panel.appendChild(vivaWrap);
      }

      resultsSection.appendChild(panel);

      // export
      var exportBar = el('div', { class: 'exportbar' });
      if (downloadsCap) {
        exportBar.appendChild(el('button', { class: 'btn-ghost', type: 'button', text: 'Download as text file', onclick: exportPack }));
      }
      if (state.exportNote) exportBar.appendChild(el('span', { class: 'status-line', text: state.exportNote, style: 'margin-left:0.8rem;' }));
      resultsSection.appendChild(exportBar);
    }
    app.appendChild(resultsSection);

    app.appendChild(el('footer', { class: 'note', text: 'Padhle grounds everything in the text you paste — always double check facts against your textbook before an exam.' }));
  }

  function renderMcqs() {
    var wrap = el('div');
    var mcqs = state.results.mcqs || [];
    if (!mcqs.length) { wrap.appendChild(el('div', { class: 'empty-note', text: 'No MCQs came back.' })); return wrap; }

    if (!state.quiz) {
      wrap.appendChild(el('p', { class: 'empty-note', text: mcqs.length + ' questions ready. Take them as a quiz, one at a time.' }));
      wrap.appendChild(el('button', { class: 'btn-secondary', type: 'button', text: 'Take this as a quiz', onclick: startQuiz }));
      return wrap;
    }

    if (state.reviewMode) {
      mcqs.forEach(function (q, i) {
        var item = el('div', { class: 'review-item' });
        item.appendChild(el('div', { class: 'review-q', text: (i + 1) + '. ' + q.question }));
        q.options.forEach(function (opt, oi) {
          item.appendChild(el('div', { class: 'review-opt' + (oi === q.correctIndex ? ' correct' : ''), text: String.fromCharCode(97 + oi) + ') ' + opt + (oi === q.correctIndex ? ' — correct' : '') }));
        });
        if (q.explanation) item.appendChild(el('div', { class: 'review-explain', text: q.explanation }));
        wrap.appendChild(item);
      });
      wrap.appendChild(el('div', { class: 'quiz-score-actions' }, [
        el('button', { class: 'btn-secondary', type: 'button', text: 'Retake quiz', onclick: startQuiz }),
        el('button', { class: 'btn-ghost', type: 'button', text: 'Back', onclick: function () { state.reviewMode = false; state.quiz = null; render(); } })
      ]));
      return wrap;
    }

    if (state.quiz.finished) {
      var card = el('div', { class: 'quiz-card' });
      var scoreDiv = el('div', { class: 'quiz-score' }, [
        el('div', { class: 'big', text: state.quiz.score + ' / ' + mcqs.length }),
        el('div', { class: 'sublabel', text: 'questions correct' })
      ]);
      card.appendChild(scoreDiv);
      card.appendChild(el('div', { class: 'quiz-score-actions' }, [
        el('button', { class: 'btn-secondary', type: 'button', text: 'Retake quiz', onclick: startQuiz }),
        el('button', { class: 'btn-ghost', type: 'button', text: 'Review answers', onclick: function () { state.reviewMode = true; render(); } })
      ]));
      wrap.appendChild(card);
      return wrap;
    }

    var q = mcqs[state.quiz.index];
    var card2 = el('div', { class: 'quiz-card' });
    card2.appendChild(el('div', { class: 'quiz-progress', text: 'Question ' + (state.quiz.index + 1) + ' of ' + mcqs.length + '  ·  Score so far: ' + state.quiz.score }));
    card2.appendChild(el('div', { class: 'quiz-q', text: q.question }));
    q.options.forEach(function (opt, oi) {
      var cls = 'quiz-option';
      if (state.quiz.answered) {
        if (oi === q.correctIndex) cls += ' correct';
        else if (oi === state.quiz.selected) cls += ' incorrect';
      }
      var optBtn = el('button', {
        class: cls,
        type: 'button',
        text: String.fromCharCode(97 + oi) + ') ' + opt,
        onclick: state.quiz.answered ? null : function () { answerQuiz(oi); }
      });
      if (state.quiz.answered) optBtn.setAttribute('disabled', 'true');
      card2.appendChild(optBtn);
    });
    if (state.quiz.answered && q.explanation) {
      card2.appendChild(el('div', { class: 'quiz-explain', text: q.explanation }));
    }
    if (state.quiz.answered) {
      card2.appendChild(el('div', { class: 'quiz-nav' }, [
        el('button', { class: 'btn-secondary', type: 'button', text: (state.quiz.index + 1 >= mcqs.length) ? 'See score' : 'Next question', onclick: nextQuiz })
      ]));
    }
    wrap.appendChild(card2);
    return wrap;
  }

  // ---------- init ----------

  render();

  (async function initCapabilities() {
    try { sampleFn = await window.claude.use('sample'); } catch (e) { sampleFn = null; }
    sampleReady = true;
    try { downloadsCap = await window.claude.use('downloads'); } catch (e) { downloadsCap = null; }
    downloadsReady = true;
    render();
  })();
})();