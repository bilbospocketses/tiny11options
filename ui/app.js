"use strict";

const ps   = (msg) => window.chrome.webview.postMessage(msg);
const onPs = (cb)  => window.chrome.webview.addEventListener('message', e => cb(JSON.parse(e.data)));

// Theme — stored in localStorage (key 'tiny11-theme'). On first run, read system preference.
// Persistence lives in the WebView2 userdata folder under %LOCALAPPDATA%\tiny11options\webview2-userdata\.
function detectSystemTheme() {
    return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}
function applyTheme(theme) {
    document.documentElement.dataset.theme = theme;
    const btn = document.getElementById('theme-toggle');
    if (btn) {
        btn.textContent = theme === 'dark' ? '\u{1F319}' : '\u{2600}\u{FE0F}';
        btn.title = theme === 'dark' ? 'Switch to light theme' : 'Switch to dark theme';
    }
}
function initTheme() {
    const stored = localStorage.getItem('tiny11-theme');
    const theme = (stored === 'light' || stored === 'dark') ? stored : detectSystemTheme();
    applyTheme(theme);
    document.getElementById('theme-toggle').addEventListener('click', () => {
        const next = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
        localStorage.setItem('tiny11-theme', next);
        applyTheme(next);
    });
}

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
    fastBuild: false,
    drilledCategory: null,
    search: '',
    building: false,
    completed: null,
    progress: null,
    buildDetailsOpen: false,
};

// When the user picks or types a scratch directory, prefill the output ISO path with
// "<scratchDir>\tiny11.iso" — but only if outputPath is empty so we never clobber a
// custom value. Output goes alongside scratchDir's tiny11/ source folder, not inside it,
// so oscdimg never sees its own output as input.
function prefillOutputIfEmpty() {
    if (state.outputPath || !state.scratchDir) return;
    const trimmed = state.scratchDir.replace(/[\\/]+$/, '');
    const sep = (trimmed.includes('/') && !trimmed.includes('\\')) ? '/' : '\\';
    state.outputPath = trimmed + sep + 'tiny11.iso';
}

function renderStep() {
    // Preserve focus + cursor position on the search input across re-renders, so typing isn't disrupted.
    const wasFocusedSearch = document.activeElement && document.activeElement.id === 'search';
    const cursorPos = wasFocusedSearch ? document.activeElement.selectionStart : 0;

    const root = document.getElementById('content');
    clear(root);
    document.querySelectorAll('.breadcrumb span').forEach(s => {
        s.classList.toggle('active', s.dataset.step === state.step);
    });
    if (state.step === 'source')    root.appendChild(renderSourceStep());
    if (state.step === 'customize') root.appendChild(renderCustomizeStep());
    if (state.step === 'build')     root.appendChild(renderBuildStep());
    updateNav();

    if (wasFocusedSearch) {
        const restored = document.getElementById('search');
        if (restored) {
            restored.focus();
            restored.setSelectionRange(cursorPos, cursorPos);
        }
    }
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

function renderBuildStep() {
    if (state.building) return renderProgress();
    if (state.completed) return renderComplete();

    const resolved = reconcile();
    const totalApplied = state.catalog.items.filter(i => resolved[i.id].effective === 'apply').length;
    const editionLabel = (state.editions || []).find(e => e.index === state.edition);

    return el('section', { class: 'build' },
        el('h2', null, 'Ready to build'),
        el('dl', null,
            el('dt', null, 'Source'),     el('dd', null, state.source || ''),
            el('dt', null, 'Edition'),    el('dd', null, editionLabel ? editionLabel.name : String(state.edition || '')),
            el('dt', null, 'Scratch'),    el('dd', null, state.scratchDir || ''),
            el('dt', null, 'Output ISO'),
            el('dd', { class: 'row' },
                el('input', {
                    id: 'out-input', type: 'text', value: state.outputPath || '',
                    onchange: e => state.outputPath = e.target.value
                }),
                el('button', { onclick: () => ps({ type: 'browse-output' }) }, 'Browse...')
            ),
            el('dt', null, 'Changes'), el('dd', null, `${totalApplied} items applied`)
        ),
        el('button', {
            class: 'primary',
            onclick: () => {
                state.building = true;
                renderStep();
                ps({
                    type: 'build',
                    source: state.source,
                    imageIndex: state.edition,
                    scratchDir: state.scratchDir,
                    outputPath: state.outputPath,
                    unmountSource: state.unmountSource,
                    fastBuild: state.fastBuild,
                    selections: state.selections,
                });
            }
        }, 'Build ISO')
    );
}

function renderProgress() {
    const p = state.progress || {};
    const progressBar = el('progress', { max: 100, value: p.percent || 0 });

    const editionEntry = (state.editions || []).find(e => e.index === state.edition);
    const editionLabel = editionEntry
        ? `${editionEntry.name} (index ${editionEntry.index})`
        : (state.edition !== null ? `index ${state.edition}` : '—');
    const buildMode = state.fastBuild
        ? 'Fast build (no recovery compression — output ISO typically 7–8 GB)'
        : 'Standard (with recovery compression — output ISO roughly 2 GB smaller)';
    const resolved = reconcile();
    const appliedItems = state.catalog.items.filter(i => resolved[i.id].effective === 'apply');

    return el('section', { class: 'progress' },
        el('h2', null, 'Building tiny11 image...'),
        progressBar,
        el('p', null, `Phase: ${p.phase || '—'}`),
        el('p', null, `Step: ${p.step || '—'}`),
        el('button', { onclick: () => ps({ type: 'cancel' }) }, 'Cancel build'),
        el('details', {
            class: 'build-details',
            open: state.buildDetailsOpen,
            ontoggle: ev => { state.buildDetailsOpen = ev.target.open; }
        },
            el('summary', null, 'Show build details'),
            el('dl', { class: 'build-details-summary' },
                el('dt', null, 'Edition'),     el('dd', null, editionLabel),
                el('dt', null, 'Build mode'),  el('dd', null, buildMode),
                el('dt', null, 'Output ISO'),  el('dd', null, state.outputPath || '—')
            ),
            el('h3', null, `Items being removed (${appliedItems.length}):`),
            el('ul', { class: 'build-details-items' },
                appliedItems.map(it => el('li', null, it.displayName))
            )
        )
    );
}

function renderComplete() {
    const c = state.completed;
    return el('section', { class: 'complete' },
        el('h2', null, 'Build complete'),
        el('p', null, `Output: ${c.outputPath}`),
        el('button', { onclick: () => ps({ type: 'open-folder', path: c.outputPath }) }, 'Open output folder'),
        el('button', { onclick: () => ps({ type: 'close' }) }, 'Close')
    );
}

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

// Smart bulk-select button. Acts on the visible items passed in, skipping any locked ones.
// Label flips between "Check all" and "Uncheck all" depending on whether every unlocked item
// in the visible set is already 'apply'.
function bulkSelectButton(items, resolved) {
    const unlocked = items.filter(it => !resolved[it.id].locked);
    const allChecked = unlocked.length > 0 && unlocked.every(it => state.selections[it.id] === 'apply');
    const label = allChecked ? 'Uncheck all' : 'Check all';
    const target = allChecked ? 'skip' : 'apply';
    return el('button', {
        disabled: unlocked.length === 0,
        onclick: () => {
            unlocked.forEach(it => state.selections[it.id] = target);
            renderStep();
        }
    }, label);
}

// Handler for clicking anywhere on a non-locked item row. Toggles the row's checkbox
// unless the click landed on the checkbox itself (in which case the native handler
// already fired) or on a link/button.
function rowClickHandler(ev) {
    const tag = ev.target.tagName;
    if (tag === 'INPUT' || tag === 'A' || tag === 'BUTTON') return;
    const cb = ev.currentTarget.querySelector('input[type="checkbox"]');
    if (!cb || cb.disabled) return;
    cb.checked = !cb.checked;
    cb.dispatchEvent(new Event('change'));
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

    const term = (state.search || '').trim().toLowerCase();
    if (term) return renderSearchResults(term, resolved);

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
            el('input', {
                id: 'search', type: 'text', value: state.search || '',
                placeholder: 'Search across all items...',
                oninput: ev => { state.search = ev.target.value; renderStep(); },
                onkeydown: ev => { if (ev.key === 'Escape') { state.search = ''; renderStep(); } }
            }),
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

function renderSearchResults(term, resolved) {
    const matchingItems = state.catalog.items.filter(it =>
        (it.displayName + ' ' + (it.description || '')).toLowerCase().includes(term)
    );
    const totalApplied = matchingItems.filter(it => resolved[it.id].effective === 'apply').length;

    const itemElements = matchingItems.map(it => {
        const r = resolved[it.id];
        const cat = state.catalog.categories.find(c => c.id === it.category);
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
            el('span', { class: 'cat-badge' }, cat ? cat.displayName : it.category),
            el('p', { class: 'item-desc' }, it.description)
        ];
        if (r.locked) {
            liChildren.push(el('p', { class: 'lock' }, `🔒 Locked — kept because: ${r.lockedBy.join(', ')}`));
        }
        const liOpts = r.locked ? { class: 'locked' } : { class: 'clickable', onclick: rowClickHandler };
        return el('li', liOpts, ...liChildren);
    });

    return el('section', { class: 'customize' },
        el('div', { class: 'row' },
            el('input', {
                id: 'search', type: 'text', value: state.search || '',
                placeholder: 'Search across all items...',
                oninput: ev => { state.search = ev.target.value; renderStep(); },
                onkeydown: ev => { if (ev.key === 'Escape') { state.search = ''; renderStep(); } }
            }),
            el('span', { class: 'counter' }, `Items matching: ${matchingItems.length} (${totalApplied} applied)`)
        ),
        el('div', { class: 'row' },
            el('button', { onclick: () => { state.search = ''; renderStep(); } }, '< Back to categories'),
            bulkSelectButton(matchingItems, resolved),
            el('button', { onclick: () => ps({ type: 'save-profile-request', selections: state.selections }) }, 'Save profile...'),
            el('button', { onclick: () => ps({ type: 'load-profile-request' }) }, 'Load profile...'),
            el('button', { onclick: () => { state.selections = {}; renderStep(); } }, 'Reset to defaults')
        ),
        matchingItems.length === 0
            ? el('p', { class: 'hint' }, `No items match "${state.search}".`)
            : el('ul', { class: 'item-list' }, itemElements)
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
        const liOpts = r.locked ? { class: 'locked' } : { class: 'clickable', onclick: rowClickHandler };
        return el('li', liOpts, ...liChildren);
    });

    return el('section', { class: 'drill' },
        el('div', { class: 'row' },
            el('button', {
                onclick: () => { state.drilledCategory = null; renderStep(); }
            }, '< Back to categories'),
            bulkSelectButton(items, resolved)
        ),
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
                placeholder: 'C:\\path\\to\\Win11.iso or drive letter where Windows 11 DVD or ISO are mounted (ex. E:)',
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
                onchange: e => { state.scratchDir = e.target.value; prefillOutputIfEmpty(); }
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
        ),
        el('label', { class: 'checkbox-label' },
            el('input', {
                id: 'fast-build', type: 'checkbox',
                checked: state.fastBuild,
                onchange: e => state.fastBuild = e.target.checked
            }),
            'Fast build (skip recovery compression)'
        ),
        el('p', { class: 'hint' },
            'Skips DISM /Cleanup-Image and /Export-Image /Compress:recovery. ' +
            'Saves 25–40 minutes per build. With fast build the output ISO is typically ' +
            '7–8 GB; leaving fast build off enables recovery compression and shrinks the ' +
            'ISO by roughly 2 GB. Both produce functionally identical installs. Recommended ' +
            'for VM testing or iterative builds where ISO size doesn’t matter.'
        )
    );
    return section;
}

document.addEventListener('DOMContentLoaded', () => { initTheme(); renderStep(); });

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
        if (msg.field === 'scratch') { state.scratchDir = msg.path; prefillOutputIfEmpty(); renderStep(); }
        if (msg.field === 'output')  { state.outputPath = msg.path; renderStep(); }
    } else if (msg.type === 'profile-loaded') {
        state.selections = {};
        for (const [k, v] of Object.entries(msg.selections)) state.selections[k] = v;
        renderStep();
    }
});

// Extended onPs handler — Task 22 build-progress/complete/error + profile-saved + handler-error.
onPs(msg => {
    if (msg.type === 'build-progress') {
        state.progress = msg;
        renderStep();
    } else if (msg.type === 'build-complete') {
        state.building = false;
        state.completed = msg;
        renderStep();
    } else if (msg.type === 'build-error') {
        state.building = false;
        const root = document.getElementById('content');
        clear(root);
        root.appendChild(el('section', { class: 'error' },
            el('h2', null, 'Build failed'),
            el('p', null, msg.message || 'Unknown error'),
            el('button', { onclick: () => ps({ type: 'close' }) }, 'Close')
        ));
    } else if (msg.type === 'profile-saved') {
        // v1: log only; future: transient toast.
        console.log('Profile saved:', msg.path);
    } else if (msg.type === 'handler-error') {
        console.error('Handler error:', msg.message);
    }
});
