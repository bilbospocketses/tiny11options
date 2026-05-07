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

// Stub replaced in task 22:
function renderBuildStep()     { return el('p', null, 'Build step (task 22)'); }

function buildSelectionsIfEmpty() {
    if (Object.keys(state.selections).length > 0) return;
    state.catalog.items.forEach(it => state.selections[it.id] = it.default);
}

function reconcile() {
    const pinnedBy = {};
    state.catalog.items.forEach(it => {
        if (state.selections[it.id] === 'skip') {
            (it.runtimeDepsOn || []).forEach(dep => {
                if (!pinnedBy[dep]) pinnedBy[dep] = [];
                pinnedBy[dep].push(it.id);
            });
        }
    });
    const resolved = {};
    state.catalog.items.forEach(it => {
        const locked = !!pinnedBy[it.id];
        resolved[it.id] = {
            user: state.selections[it.id],
            effective: locked ? 'skip' : state.selections[it.id],
            locked,
            lockedBy: pinnedBy[it.id] || [],
        };
    });
    return resolved;
}

function countsByCategory(resolved) {
    const out = {};
    state.catalog.categories.forEach(c => {
        const items = state.catalog.items.filter(i => i.category === c.id);
        out[c.id] = {
            applied: items.filter(i => resolved[i.id].effective === 'apply').length,
            total: items.length
        };
    });
    return out;
}

function renderCustomizeStep() {
    buildSelectionsIfEmpty();
    const resolved = reconcile();
    if (state.drilledCategory) return renderDrillin(state.drilledCategory, resolved);

    const counts = countsByCategory(resolved);
    const totalApplied = state.catalog.items.filter(i => resolved[i.id].effective === 'apply').length;

    const cards = state.catalog.categories.map(c => {
        const cnt = counts[c.id];
        const indicator = cnt.applied === cnt.total ? '[✓]' : cnt.applied === 0 ? '[ ]' : '[~]';
        return el('div', {
            class: 'card',
            data: { cat: c.id },
            onclick: () => { state.drilledCategory = c.id; renderStep(); }
        },
            el('h3', null, c.displayName),
            el('p',  null, c.description),
            el('span', { class: 'cat-count' }, `${indicator} ${cnt.applied}/${cnt.total}`)
        );
    });

    return el('section', { class: 'customize' },
        el('div', { class: 'row' },
            el('input', { id: 'search', type: 'text', placeholder: 'Search...' }),
            el('span', { class: 'counter' }, `Items applied: ${totalApplied}/${state.catalog.items.length}`)
        ),
        el('div', { class: 'row' },
            el('button', { onclick: () => ps({ type: 'save-profile-request', selections: state.selections }) }, 'Save profile...'),
            el('button', { onclick: () => ps({ type: 'load-profile-request' }) }, 'Load profile...'),
            el('button', { onclick: () => { state.selections = {}; renderStep(); } }, 'Reset to defaults')
        ),
        el('div', { class: 'card-grid' }, cards)
    );
}

function renderDrillin(catId, resolved) {
    const cat = state.catalog.categories.find(c => c.id === catId);
    const items = state.catalog.items.filter(i => i.category === catId);

    const itemElements = items.map(it => {
        const r = resolved[it.id];
        const liChildren = [
            el('input', {
                type: 'checkbox',
                checked: r.effective === 'apply',
                disabled: r.locked,
                data: { id: it.id },
                onchange: ev => {
                    state.selections[it.id] = ev.target.checked ? 'apply' : 'skip';
                    renderStep();
                }
            }),
            el('span', { class: 'item-name' }, it.displayName),
            el('p', { class: 'item-desc' }, it.description)
        ];
        if (r.locked) {
            liChildren.push(el('p', { class: 'lock' }, `🔒 Locked — kept because: ${r.lockedBy.join(', ')}`));
        }
        return el('li', { class: r.locked ? 'locked' : '' }, ...liChildren);
    });

    return el('section', { class: 'drill' },
        el('button', {
            onclick: () => { state.drilledCategory = null; renderStep(); }
        }, '< Back to categories'),
        el('h2', null, cat.displayName),
        el('ul', { class: 'item-list' }, itemElements)
    );
}

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
