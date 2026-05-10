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
    fastBuild: true,
    coreMode: false,
    enableNet35: false,
    drilledCategory: null,
    search: '',
    building: false,
    completed: null,
    progress: null,
    buildDetailsOpen: false,
};

// Snapshot of selections taken when "Save profile..." is clicked, used after the
// browse-save-file dialog returns a path. Decouples user click time from dialog
// completion so concurrent state changes (rare) can't poison the saved profile.
let pendingSaveProfileSelections = null;

// When the user picks or types a scratch directory, prefill the output ISO path with
// "<scratchDir>\tiny11.iso" (or tiny11core.iso in Core mode) — but only if outputPath is
// empty so we never clobber a custom value. Output goes alongside scratchDir's tiny11/
// source folder, not inside it, so oscdimg never sees its own output as input.
function prefillOutputIfEmpty() {
    if (state.outputPath || !state.scratchDir) return;
    const trimmed = state.scratchDir.replace(/[\\/]+$/, '');
    const sep = (trimmed.includes('/') && !trimmed.includes('\\')) ? '/' : '\\';
    const filename = state.coreMode ? 'tiny11core.iso' : 'tiny11.iso';
    state.outputPath = trimmed + sep + filename;
}

// When coreMode toggles, swap the default ISO filename if the user hasn't customized it.
function syncOutputFilenameToMode() {
    if (!state.scratchDir || !state.outputPath) return;
    const trimmed = state.scratchDir.replace(/[\\/]+$/, '');
    const sep = (trimmed.includes('/') && !trimmed.includes('\\')) ? '/' : '\\';
    const prev = trimmed + sep + (state.coreMode ? 'tiny11.iso' : 'tiny11core.iso');
    if (state.outputPath === prev) {
        state.outputPath = null;
        prefillOutputIfEmpty();
    }
}

function renderStep() {
    // Preserve focus + cursor position on the search input across re-renders, so typing isn't disrupted.
    const wasFocusedSearch = document.activeElement && document.activeElement.id === 'search';
    const cursorPos = wasFocusedSearch ? document.activeElement.selectionStart : 0;

    const root = document.getElementById('content');
    clear(root);
    document.querySelectorAll('.breadcrumb span').forEach(s => {
        s.classList.toggle('active', s.dataset.step === state.step);
        if (s.dataset.step === 'customize') {
            if (state.coreMode) s.setAttribute('data-disabled', 'true');
            else s.removeAttribute('data-disabled');
        }
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
    else if (state.step === 'build') state.step = state.coreMode ? 'source' : 'customize';
    state.drilledCategory = null;
    renderStep();
});
document.getElementById('next-btn').addEventListener('click', () => {
    if (state.step === 'source') state.step = state.coreMode ? 'build' : 'customize';
    else if (state.step === 'customize') state.step = 'build';
    renderStep();
});

function renderBuildStep() {
    if (state.building) return renderProgress();
    if (state.completed) return renderComplete();

    const resolved = reconcile();
    const totalApplied = state.catalog.items.filter(i => resolved[i.id].effective === 'apply').length;
    const editionLabel = (state.editions || []).find(e => e.index === state.edition);

    // Summary rows differ between Core and standard mode.
    const modeSummaryRows = state.coreMode
        ? [
            el('dt', null, 'Mode'),    el('dd', null, 'Core'),
            el('dt', null, '.NET 3.5'), el('dd', null, state.enableNet35 ? 'Enabled' : 'Disabled'),
          ]
        : [
            el('dt', null, 'Changes'), el('dd', null, `${totalApplied} items applied`),
          ];

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
                el('button', { onclick: () => ps({ type: 'browse-save-file', payload: { context: 'output', title: 'Save tiny11 ISO as...', filter: 'ISO files|*.iso|All files|*.*', defaultName: state.coreMode ? 'tiny11core.iso' : 'tiny11.iso' } }) }, 'Browse...')
            ),
            ...modeSummaryRows
        ),
        el('button', {
            class: 'primary',
            onclick: () => {
                state.building = true;
                renderStep();
                ps({
                    type: 'start-build',
                    payload: {
                        source: state.source,
                        edition: state.edition,
                        scratchDir: state.scratchDir,
                        outputIso: state.outputPath,
                        unmountSource: state.unmountSource,
                        fastBuild: state.fastBuild,
                        selections: state.selections,
                        coreMode: state.coreMode,
                        enableNet35: state.enableNet35,
                    },
                });
            }
        }, 'Build ISO')
    );
}

function renderCoreCleanupBlock() {
    const sd = (state.scratchDir || '').replace(/[\\/]+$/, '');
    if (!sd) return null;
    const mount = `${sd}\\mount`;
    const source = `${sd}\\source`;
    const cmds = [
        `dism /unmount-image /mountdir:"${mount}" /discard`,
        `dism /cleanup-mountpoints`,
        `takeown /F "${mount}" /R /D Y`,
        `icacls "${mount}" /grant Administrators:F /T /C`,
        `Remove-Item -Path "${mount}" -Recurse -Force -ErrorAction SilentlyContinue`,
        `Remove-Item -Path "${source}" -Recurse -Force -ErrorAction SilentlyContinue`,
    ];
    return el('div', { class: 'core-cleanup' },
        el('p', { class: 'core-cleanup-intro' },
            '⚠ If you cancel during the WinSxS wipe phase, the scratch directory is left in a non-resumable state. To clean up, run these in an elevated PowerShell prompt before starting another build:'
        ),
        el('pre', { class: 'cleanup-cmd' }, cmds.join('\n'))
    );
}

function renderProgress() {
    const p = state.progress || {};
    const progressBar = el('progress', { max: 100, value: p.percent || 0 });

    const editionEntry = (state.editions || []).find(e => e.index === state.edition);
    const editionLabel = editionEntry
        ? `${editionEntry.name} (index ${editionEntry.index})`
        : (state.edition !== null ? `index ${state.edition}` : '—');
    const buildMode = state.coreMode
        ? 'Core (WinSxS wipe + fixed compression sequence)'
        : state.fastBuild
            ? 'Fast build (no recovery compression — output ISO typically 7–8 GB)'
            : 'Standard (with recovery compression — output ISO roughly 2 GB smaller)';
    const resolved = reconcile();
    const appliedItems = state.catalog.items.filter(i => resolved[i.id].effective === 'apply');

    // Build-details inner content differs by mode.
    const detailsInner = state.coreMode
        ? [
            el('dl', { class: 'build-details-summary' },
                el('dt', null, 'Edition'),    el('dd', null, editionLabel),
                el('dt', null, 'Build mode'), el('dd', null, buildMode),
                el('dt', null, 'Output ISO'), el('dd', null, state.outputPath || '—')
            ),
            renderCoreCleanupBlock(),
          ]
        : [
            el('dl', { class: 'build-details-summary' },
                el('dt', null, 'Edition'),    el('dd', null, editionLabel),
                el('dt', null, 'Build mode'), el('dd', null, buildMode),
                el('dt', null, 'Output ISO'), el('dd', null, state.outputPath || '—')
            ),
            el('h3', null, `Items being removed (${appliedItems.length}):`),
            el('ul', { class: 'build-details-items' },
                appliedItems.map(it => el('li', null, it.displayName))
            ),
          ];

    return el('section', { class: 'progress' },
        el('h2', null, 'Building tiny11 image...'),
        progressBar,
        el('p', null, `Phase: ${p.phase || '—'}`),
        el('p', null, `Step: ${p.step || '—'}`),
        el('button', { onclick: () => ps({ type: 'cancel-build', payload: {} }) }, 'Cancel build'),
        el('details', {
            class: 'build-details',
            open: state.buildDetailsOpen,
            ontoggle: ev => { state.buildDetailsOpen = ev.target.open; }
        },
            el('summary', null, 'Show build details'),
            ...detailsInner
        )
    );
}

function renderComplete() {
    const c = state.completed;
    return el('section', { class: 'complete' },
        el('h2', null, 'Build complete'),
        el('p', null, `Output: ${c.outputPath}`),
        el('button', { onclick: () => ps({ type: 'open-folder', payload: { path: c.outputPath } }) }, 'Open output folder'),
        el('button', { onclick: () => ps({ type: 'close', payload: {} }) }, 'Close')
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
            el('button', { onclick: () => {
                pendingSaveProfileSelections = JSON.parse(JSON.stringify(state.selections));
                ps({ type: 'browse-save-file', payload: { context: 'profile-save', title: 'Save profile as...', filter: 'JSON|*.json', defaultName: 'profile.json' } });
            } }, 'Save profile...'),
            el('button', { onclick: () => ps({ type: 'browse-file', payload: { context: 'profile-load', title: 'Load profile...', filter: 'JSON|*.json|All files|*.*' } }) }, 'Load profile...'),
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
        el('div', { class: 'sticky-header' },
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
                el('button', { onclick: () => {
                    pendingSaveProfileSelections = JSON.parse(JSON.stringify(state.selections));
                    ps({ type: 'browse-save-file', payload: { context: 'profile-save', title: 'Save profile as...', filter: 'JSON|*.json', defaultName: 'profile.json' } });
                } }, 'Save profile...'),
                el('button', { onclick: () => ps({ type: 'browse-file', payload: { context: 'profile-load', title: 'Load profile...', filter: 'JSON|*.json|All files|*.*' } }) }, 'Load profile...'),
                el('button', { onclick: () => { state.selections = {}; renderStep(); } }, 'Reset to defaults')
            )
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
        el('div', { class: 'sticky-header' },
            el('div', { class: 'row' },
                el('button', {
                    onclick: () => { state.drilledCategory = null; renderStep(); }
                }, '< Back to categories'),
                bulkSelectButton(items, resolved)
            ),
            el('h2', null, cat.displayName)
        ),
        el('ul', { class: 'item-list' }, itemElements)
    );
}

function renderSourceStep() {
    const editionsOptions = (state.editions || []).map(e =>
        el('option', { value: e.index, selected: state.edition === e.index }, `${e.name} (index ${e.index})`)
    );

    const errorBanner = el('div', { id: 'src-error', class: 'error hidden' });

    // Fast-build row + hint always render. When Core mode is on the input is
    // disabled AND visually unchecked (a disabled-but-checked box reads as
    // "forced active in this state" which is wrong — Core ignores the flag
    // entirely). state.fastBuild is preserved untouched so the user's prior
    // preference returns when Core is unchecked. The label + adjacent hint
    // grey out via CSS (.checkbox-label:has(input:disabled) + sibling .hint).
    // A title tooltip on label + input explains the inactive state on hover.
    const fastBuildDisabled = state.coreMode;
    const fastBuildTooltip = 'Unavailable when Core mode is enabled';
    const fastBuildRow = [
        el('label', {
            class: 'checkbox-label',
            title: fastBuildDisabled ? fastBuildTooltip : null
        },
            el('input', {
                id: 'fast-build', type: 'checkbox',
                checked: fastBuildDisabled ? false : state.fastBuild,
                disabled: fastBuildDisabled,
                title: fastBuildDisabled ? fastBuildTooltip : null,
                onchange: e => state.fastBuild = e.target.checked
            }),
            'Fast build (skip recovery compression)'
        ),
        el('p', { class: 'hint' },
            'Skips DISM /Cleanup-Image and /Export-Image /Compress:recovery. ' +
            'Saves 25–40 minutes per build. With fast build the output ISO is typically ' +
            '7–8 GB; leaving fast build off enables recovery compression and shrinks the ' +
            'ISO by roughly 2 GB. Both produce functionally identical installs. Recommended ' +
            'for VM testing or iterative builds where ISO size doesn\'t matter.'
        ),
    ];

    // Core warning panel — shown only when coreMode is on.
    const coreWarning = state.coreMode
        ? el('div', { class: 'core-warning' },
            'tiny11 Core builds a significantly smaller image, but the output is not serviceable: ' +
            'you cannot install Windows Updates, add languages, or enable Windows features after install. ' +
            'Suitable for VM testing or short-lived development environments — not as a daily-driver Windows install.'
          )
        : null;

    // .NET 3.5 checkbox + hint — shown only when coreMode is on.
    const net35Row = state.coreMode
        ? [
            el('label', { class: 'checkbox-label' },
                el('input', {
                    id: 'enable-net35', type: 'checkbox',
                    checked: state.enableNet35,
                    onchange: e => { state.enableNet35 = e.target.checked; }
                }),
                'Enable .NET 3.5 (legacy app compatibility)'
            ),
            el('p', { class: 'hint' },
                '.NET 3.5 must be enabled at build time — cannot be added after install. Adds ~100 MB.'
            ),
          ]
        : [];

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
                    ps({ type: 'validate-iso', payload: { path: state.source } });
                    renderStep();
                }
            }),
            el('button', { id: 'src-browse', onclick: () => ps({ type: 'browse-file', payload: { context: 'source', title: 'Select Win11 ISO', filter: 'ISO files|*.iso|All files|*.*' } }) }, 'Browse...')
        ),
        errorBanner,
        el('label', null, 'Edition'),
        el('div', { class: 'row' },
            el('select', {
                id: 'edition-select',
                disabled: !state.editions,
                onchange: e => { state.edition = parseInt(e.target.value, 10); updateNav(); }
            }, editionsOptions),
            el('button', { class: 'browse-spacer', 'aria-hidden': 'true', tabindex: '-1' }, 'Browse...')
        ),
        el('label', null, 'Scratch directory'),
        el('div', { class: 'row' },
            el('input', {
                id: 'scratch-input', type: 'text', value: state.scratchDir || '',
                onchange: e => { state.scratchDir = e.target.value; prefillOutputIfEmpty(); }
            }),
            el('button', { onclick: () => ps({ type: 'browse-folder', payload: { context: 'scratch', title: 'Select scratch directory' } }) }, 'Browse...')
        ),
        el('label', { class: 'checkbox-label' },
            el('input', {
                id: 'unmount-source', type: 'checkbox',
                checked: state.unmountSource,
                onchange: e => state.unmountSource = e.target.checked
            }),
            'Unmount source ISO when build finishes'
        ),
        ...fastBuildRow,
        el('label', { class: 'checkbox-label' },
            el('input', {
                id: 'core-mode', type: 'checkbox',
                checked: state.coreMode,
                onchange: e => {
                    state.coreMode = e.target.checked;
                    syncOutputFilenameToMode();
                    renderStep();
                }
            }),
            'Build tiny11 Core (smaller, non-serviceable)'
        ),
        coreWarning,
        ...net35Row
    );
    return section;
}

document.addEventListener('DOMContentLoaded', () => { initTheme(); renderStep(); });

onPs(msg => {
    const p = msg.payload || {};
    if (msg.type === 'iso-validated') {
        state.editions = p.editions;
        state.edition = (p.editions && p.editions[0] && p.editions[0].index) || null;
        state.source = p.path || state.source;
        renderStep();
    } else if (msg.type === 'iso-error') {
        const banner = document.getElementById('src-error');
        if (banner) {
            banner.classList.remove('hidden');
            banner.textContent = p.message;
        }
    } else if (msg.type === 'browse-result') {
        if (!p.path) return; // user cancelled the dialog
        if (p.context === 'source')  { state.source = p.path; renderStep(); ps({ type: 'validate-iso', payload: { path: p.path } }); }
        else if (p.context === 'scratch') { state.scratchDir = p.path; prefillOutputIfEmpty(); renderStep(); }
        else if (p.context === 'output')  { state.outputPath = p.path; renderStep(); }
        else if (p.context === 'profile-save') {
            ps({ type: 'save-profile', payload: { path: p.path, selections: pendingSaveProfileSelections } });
            pendingSaveProfileSelections = null;
        }
        else if (p.context === 'profile-load') {
            ps({ type: 'load-profile', payload: { path: p.path } });
        }
    } else if (msg.type === 'profile-loaded') {
        state.selections = {};
        for (const [k, v] of Object.entries(p.selections || {})) state.selections[k] = v;
        renderStep();
    }
});

// Extended onPs handler — Task 22 build-progress/complete/error + profile-saved + handler-error.
onPs(msg => {
    const p = msg.payload || {};
    if (msg.type === 'build-progress') {
        state.progress = p;
        renderStep();
    } else if (msg.type === 'build-complete') {
        state.building = false;
        state.completed = p;
        renderStep();
    } else if (msg.type === 'build-error') {
        state.building = false;
        const root = document.getElementById('content');
        clear(root);
        const children = [
            el('h2', null, 'Build failed'),
            el('p', null, p.message || 'Unknown error'),
        ];
        if (p.logPath) {
            children.push(el('p', { class: 'log-hint' }, 'Full build log: ', el('code', null, p.logPath)));
        }
        if (state.coreMode && state.scratchDir) {
            const block = renderCoreCleanupBlock();
            if (block) children.push(block);
        }
        children.push(el('button', { onclick: () => ps({ type: 'close', payload: {} }) }, 'Close'));
        root.appendChild(el('section', { class: 'error' }, ...children));
    } else if (msg.type === 'profile-saved') {
        // v1: log only; future: transient toast.
        console.log('Profile saved:', p.path);
    } else if (msg.type === 'handler-error') {
        console.error('Handler error:', p.message);
    }
});

// Velopack update indicator — Task 25.
// update-available -> stash {version, changelog}, un-hide pulsing dot.
// Click -> confirm() with version + truncated changelog -> ps({type:'apply-update'}).
// update-applying -> log + disable badge while Velopack downloads.
// update-error    -> log + re-show badge so the user can retry.
let pendingUpdate = null;
onPs(msg => {
    const p = msg.payload || {};
    const badge = document.getElementById('update-badge');
    if (!badge) return;
    if (msg.type === 'update-available') {
        pendingUpdate = { version: p.version || '', changelog: p.changelog || '' };
        badge.classList.remove('hidden');
        badge.disabled = false;
        badge.title = `Update available: v${pendingUpdate.version} — click to install`;
    } else if (msg.type === 'update-applying') {
        // v1: log only; future: transient toast. UpdateHandlers ApplyAndRestartAsync
        // will tear down the process, so this state is brief.
        console.info('Update applying — process will restart.');
        badge.disabled = true;
        badge.title = 'Update downloading...';
    } else if (msg.type === 'update-error') {
        console.error('Update error:', p.message);
        if (pendingUpdate) badge.classList.remove('hidden');
        badge.disabled = false;
    }
});

document.addEventListener('DOMContentLoaded', () => {
    const badge = document.getElementById('update-badge');
    if (!badge) return;
    badge.addEventListener('click', () => {
        if (!pendingUpdate) return;
        const notes = (pendingUpdate.changelog || '').slice(0, 400);
        const trail = pendingUpdate.changelog && pendingUpdate.changelog.length > 400 ? '\n...' : '';
        if (confirm(`Install tiny11options v${pendingUpdate.version}?\n\n${notes}${trail}`)) {
            ps({ type: 'apply-update', payload: {} });
        }
    });

    // JS-initiated update-check handshake. C# UpdateHandlers receives this and
    // fires UpdateNotifier.CheckAsync; the response comes back as update-available
    // (or update-error) through the bridge. This guarantees the JS-side listener
    // is wired before C# sends, eliminating the post-Navigation race that hid
    // the badge in the prior smoke session.
    ps({ type: 'request-update-check', payload: {} });
});
