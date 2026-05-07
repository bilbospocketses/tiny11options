"use strict";

const ps   = (msg) => window.chrome.webview.postMessage(JSON.stringify(msg));
const onPs = (cb)  => window.chrome.webview.addEventListener('message', e => cb(JSON.parse(e.data)));

// DOM construction helper. children may be strings (textContent) or DOM nodes.
function el(tag, attrs, ...children) {
    const e = document.createElement(tag);
    if (attrs) {
        for (const [k, v] of Object.entries(attrs)) {
            if (v == null || v === false) continue;
            if (k === 'class')          e.className = v;
            else if (k === 'data')       Object.entries(v).forEach(([dk, dv]) => e.dataset[dk] = dv);
            else if (k === 'checked')    e.checked = !!v;
            else if (k === 'disabled')   e.disabled = !!v;
            else if (k === 'value')      e.value = v;
            else if (k.startsWith('on')) e.addEventListener(k.slice(2).toLowerCase(), v);
            else                          e.setAttribute(k, v);
        }
    }
    for (const c of children.flat()) {
        if (c == null || c === false) continue;
        if (typeof c === 'string' || typeof c === 'number') {
            e.appendChild(document.createTextNode(String(c)));
        } else {
            e.appendChild(c);
        }
    }
    return e;
}

function clear(parent) {
    while (parent.firstChild) parent.removeChild(parent.firstChild);
}

const state = {
    catalog: window.__tinyCatalog,
    selections: {},
    step: 'source',
    source: null,
    edition: null,
    editions: null,
    scratchDir: null,
    outputPath: null,
    unmountSource: true,
    drilledCategory: null,
    building: false,
    completed: null,
    progress: null,
};

function renderStep() {
    const root = document.getElementById('content');
    clear(root);
    document.querySelectorAll('.breadcrumb span').forEach(s => {
        s.classList.toggle('active', s.dataset.step === state.step);
    });
    if (state.step === 'source')    root.appendChild(renderSourceStep());
    if (state.step === 'customize') root.appendChild(renderCustomizeStep());
    if (state.step === 'build')     root.appendChild(renderBuildStep());
    updateNav();
}

function updateNav() {
    document.getElementById('back-btn').disabled = state.step === 'source' || state.building || !!state.completed;
    document.getElementById('next-btn').disabled = !canAdvance() || state.building || !!state.completed;
}

function canAdvance() {
    if (state.step === 'source')    return !!state.source && state.edition !== null;
    if (state.step === 'customize') return true;
    return false;
}

document.getElementById('back-btn').addEventListener('click', () => {
    if (state.step === 'customize') state.step = 'source';
    else if (state.step === 'build') state.step = 'customize';
    state.drilledCategory = null;
    renderStep();
});
document.getElementById('next-btn').addEventListener('click', () => {
    if (state.step === 'source')    state.step = 'customize';
    else if (state.step === 'customize') state.step = 'build';
    renderStep();
});

// Stubs replaced in tasks 21-22:
function renderCustomizeStep() { return el('p', null, 'Customize step (tasks 21)'); }
function renderBuildStep()     { return el('p', null, 'Build step (task 22)'); }

function renderSourceStep() {
    const editionsOptions = (state.editions || []).map(e =>
        el('option', { value: e.index, selected: state.edition === e.index }, `${e.name} (index ${e.index})`)
    );

    const errorBanner = el('div', { id: 'src-error', class: 'error hidden' });

    const section = el('section', { class: 'form' },
        el('label', null, 'Windows 11 ISO'),
        el('div', { class: 'row' },
            el('input', {
                id: 'src-input', type: 'text', value: state.source || '',
                placeholder: 'C:\\path\\to\\Win11.iso or drive letter (E:)',
                onchange: e => {
                    state.source = e.target.value;
                    state.editions = null;
                    state.edition = null;
                    ps({ type: 'validate-iso', path: state.source });
                    renderStep();
                }
            }),
            el('button', { id: 'src-browse', onclick: () => ps({ type: 'browse-iso' }) }, 'Browse...')
        ),
        errorBanner,
        el('label', null, 'Edition'),
        el('select', {
            id: 'edition-select',
            disabled: !state.editions,
            onchange: e => { state.edition = parseInt(e.target.value, 10); updateNav(); }
        }, editionsOptions),
        el('label', null, 'Scratch directory'),
        el('div', { class: 'row' },
            el('input', {
                id: 'scratch-input', type: 'text', value: state.scratchDir || '',
                onchange: e => state.scratchDir = e.target.value
            }),
            el('button', { onclick: () => ps({ type: 'browse-scratch' }) }, 'Browse...')
        ),
        el('label', { class: 'checkbox-label' },
            el('input', {
                id: 'unmount-source', type: 'checkbox',
                checked: state.unmountSource,
                onchange: e => state.unmountSource = e.target.checked
            }),
            'Unmount source ISO when build finishes'
        )
    );
    return section;
}

document.addEventListener('DOMContentLoaded', renderStep);

onPs(msg => {
    if (msg.type === 'iso-validated') {
        state.editions = msg.editions;
        state.edition = (msg.editions[0] && msg.editions[0].index) || null;
        state.source = msg.path || state.source;
        renderStep();
    } else if (msg.type === 'iso-error') {
        const banner = document.getElementById('src-error');
        if (banner) {
            banner.classList.remove('hidden');
            banner.textContent = msg.message;
        }
    } else if (msg.type === 'browse-result') {
        if (msg.field === 'source')  { state.source = msg.path; renderStep(); ps({ type: 'validate-iso', path: msg.path }); }
        if (msg.field === 'scratch') { state.scratchDir = msg.path; renderStep(); }
        if (msg.field === 'output')  { state.outputPath = msg.path; renderStep(); }
    } else if (msg.type === 'profile-loaded') {
        state.selections = {};
        for (const [k, v] of Object.entries(msg.selections)) state.selections[k] = v;
        renderStep();
    }
});
