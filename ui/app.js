"use strict";

const ps   = (msg) => window.chrome.webview.postMessage(msg);
const onPs = (cb)  => window.chrome.webview.addEventListener('message', e => cb(JSON.parse(e.data)));

// v1.0.8 audit WARNING ui B9: in-app modal replaces window.confirm. The
// native confirm pauses the WebView2 message pump for the modal's lifetime,
// blocking incoming chrome.webview messages from C# (build progress, cleanup
// progress, etc.). Custom overlay maintains same UX without the pause.
function showUpdateConfirmModal(pending, onInstall) {
    const modal = document.getElementById('update-confirm-modal');
    if (!modal) return;
    const versionEl = document.getElementById('update-confirm-version');
    const notesEl = document.getElementById('update-confirm-notes');
    const cancelBtn = document.getElementById('update-confirm-cancel');
    const installBtn = document.getElementById('update-confirm-install');
    if (!versionEl || !notesEl || !cancelBtn || !installBtn) return;

    versionEl.textContent = `Version ${pending.version}`;
    const notes = (pending.changelog || '').slice(0, 400);
    const trail = pending.changelog && pending.changelog.length > 400 ? '\n...' : '';
    notesEl.textContent = notes + trail;

    const hide = () => {
        modal.hidden = true;
        cancelBtn.onclick = null;
        installBtn.onclick = null;
    };
    cancelBtn.onclick = hide;
    installBtn.onclick = () => { hide(); onInstall(); };

    modal.hidden = false;
    installBtn.focus();
}

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
// Notify the WPF host of the current theme so it can apply DWMWA_USE_IMMERSIVE_DARK_MODE
// to the Windows-managed title bar. JS owns the theme model; this message is purely a
// chrome-rendering hint. No response expected.
function notifyHostThemeChanged(theme) {
    try { ps({ type: 'theme-changed', payload: { theme: theme } }); } catch (_) { /* WebView2 not ready yet — initial apply happens C#-side from system theme until JS boots */ }
}

function initTheme() {
    const stored = localStorage.getItem('tiny11-theme');
    const theme = (stored === 'light' || stored === 'dark') ? stored : detectSystemTheme();
    applyTheme(theme);
    notifyHostThemeChanged(theme);
    document.getElementById('theme-toggle').addEventListener('click', () => {
        const next = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
        localStorage.setItem('tiny11-theme', next);
        applyTheme(next);
        notifyHostThemeChanged(next);
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
    scratchDir: window.__autoScratchPath || null,
    outputPath: null,
    // v1.0.9: tracks whether outputPath is still the auto-derived value
    // (<scratchDir>\tiny11.iso or tiny11core.iso) vs a user-customized one.
    // prefillOutputIfEmpty + syncOutputFilenameToMode only write to outputPath
    // when this is true. User input or Browse-result flips it false; profile
    // load also flips false (profile values are explicit user choices).
    outputPathIsAuto: true,
    unmountSource: true,
    fastBuild: true,
    installPostBootCleanup: true,
    // A13 (v1.0.3): Step 1 build logging. Logging is on by default in the GUI
    // (matches the user's stated UX: zero-friction debugging artifact); append
    // is off by default so the log file is overwritten per build unless the
    // user explicitly opts in to accumulation. Per-session like fastBuild --
    // resets to defaults on every launcher restart, NOT persisted in profile
    // JSON or settings.json.
    logBuildOutput: true,
    appendLog: false,
    coreMode: false,
    enableNet35: false,
    drilledCategory: null,
    search: '',
    building: false,
    validating: false,         // true while we're awaiting iso-validated / iso-error
    validatingStart: 0,        // Date.now() when validation kicked off — drives the elapsed counter
    completed: null,
    progress: null,
    buildDetailsOpen: false,
    // mount-state tracking for the cancel-cleanup button. PS pipeline emits
    // build-progress {phase: 'mount-state', mountActive, mountDir, sourceDir}
    // when install.wim is mounted, and clears it on unmount. The cleanup
    // section renders only when mountActive === true; mountDir/sourceDir
    // are carried in the marker so JS doesn't have to derive them (Core
    // and Worker use different scratch-layout conventions).
    mountActive: false,
    mountDir: null,
    sourceDir: null,
    // Cleanup spinner flow (2026-05-11 redesign): when the user invokes
    // cleanup, the wizard navigates back to Step 3 (renderBuild) and shows an
    // inline spinner + status row above the Build ISO button. Build ISO stays
    // disabled while `cleaning` is true and re-enables once status reaches
    // 'success'. `pendingCleanupAfterCancel` chains start-cleanup off the
    // build-error marker we receive after a cancel-build, so the cleanup
    // script doesn't race a still-mounted DISM in the build subprocess.
    cleaning: false,
    cleanupStatus: null,
    pendingCleanupAfterCancel: false,
};

// Snapshot of selections taken when "Save profile..." is clicked, used after the
// browse-save-file dialog returns a path. Decouples user click time from dialog
// completion so concurrent state changes (rare) can't poison the saved profile.
let pendingSaveProfileSelections = null;

// Validation status line machinery. A permanent "ISO/DVD state: <message>" row
// sits below the editions dropdown — the trailing message portion changes by
// state. The line never appears/disappears so the surrounding layout never
// shifts (an earlier inline-spinner attempt changed the dropdown row width as
// the status text grew; this design fixes that).
//
// State -> message mapping:
//   no source                : "No ISO or DVD loaded"
//   validating (0-2s)        : "Mounting iso..."
//   validating (2-5s)        : "Mounting iso... finished. Determining editions..."
//   validating (5s+)         : "Mounting iso... finished. Determining editions... (Ns)"
//                              N ticks every 5s (5, 10, 15...) so users see the
//                              elapsed time is progressing, not stuck.
//   editions loaded          : "Loaded — N edition(s) detected"
//
// The validate-iso round-trip (mount + Get-Tiny11Editions + dismount) can take
// up to ~10s on retail multi-edition ISOs.
let validationTimerId = null;

function computeIsoStatusText() {
    if (state.validating) {
        const elapsed = Math.floor((Date.now() - state.validatingStart) / 1000);
        if (elapsed < 2) return 'Mounting iso...';
        const tick = Math.floor(elapsed / 5) * 5;
        return (tick >= 5)
            ? `Mounting iso... finished. Determining editions... (${tick}s)`
            : 'Mounting iso... finished. Determining editions...';
    }
    if (state.editions && state.editions.length > 0) {
        const count = state.editions.length;
        return `Loaded — ${count} edition${count === 1 ? '' : 's'} detected`;
    }
    return 'No ISO or DVD loaded';
}

function startValidationSpinner() {
    state.validating = true;
    state.validatingStart = Date.now();
    if (validationTimerId) clearInterval(validationTimerId);
    // Re-render once now so the spinner ring appears next to the status text,
    // then tick the text every second without re-rendering the whole step.
    renderStep();
    validationTimerId = setInterval(updateValidationSpinnerText, 1000);
}

function stopValidationSpinner() {
    state.validating = false;
    if (validationTimerId) { clearInterval(validationTimerId); validationTimerId = null; }
}

function updateValidationSpinnerText() {
    const node = document.getElementById('iso-status-text');
    if (!node) return;
    node.textContent = computeIsoStatusText();
}

// When the user picks or types a scratch directory, prefill the output ISO path with
// "<scratchDir>\tiny11.iso" (or tiny11core.iso in Core mode) — but only if outputPath is
// empty so we never clobber a custom value. Output goes alongside scratchDir's tiny11/
// source folder, not inside it, so oscdimg never sees its own output as input.
function prefillOutputIfEmpty() {
    if (!state.scratchDir) return;
    if (!state.outputPathIsAuto) return;
    const trimmed = state.scratchDir.replace(/[\\/]+$/, '');
    const sep = (trimmed.includes('/') && !trimmed.includes('\\')) ? '/' : '\\';
    const filename = state.coreMode ? 'tiny11core.iso' : 'tiny11.iso';
    state.outputPath = trimmed + sep + filename;
}

// When coreMode toggles, swap the default ISO filename if the user hasn't customized it.
function syncOutputFilenameToMode() {
    if (!state.scratchDir) return;
    if (!state.outputPathIsAuto) return;
    // Recompute the auto path under the new mode and overwrite. The flag check
    // above already gates this so we never clobber a user-customized path.
    const trimmed = state.scratchDir.replace(/[\\/]+$/, '');
    const sep = (trimmed.includes('/') && !trimmed.includes('\\')) ? '/' : '\\';
    const filename = state.coreMode ? 'tiny11core.iso' : 'tiny11.iso';
    state.outputPath = trimmed + sep + filename;
}

function renderStep() {
    // Preserve focus + cursor position on the search input across re-renders, so typing isn't disrupted.
    const wasFocusedSearch = document.activeElement && document.activeElement.id === 'search';
    const cursorPos = wasFocusedSearch ? document.activeElement.selectionStart : 0;

    const root = document.getElementById('content');
    clear(root);
    // v1.0.9: query .crumb-btn (was span) since breadcrumb steps are now buttons.
    const forwardOk = canMoveForward();
    document.querySelectorAll('.breadcrumb .crumb-btn').forEach(btn => {
        const target = btn.dataset.step;
        const isActive = target === state.step;
        btn.classList.toggle('active', isActive);
        if (isActive) btn.setAttribute('aria-current', 'step');
        else btn.removeAttribute('aria-current');

        // Gated state: a forward step is gated when current is 'source' AND
        // !canMoveForward. Customize is ALSO gated (skipped) when coreMode is on.
        const isForward = STEP_ORDER.indexOf(target) > STEP_ORDER.indexOf(state.step);
        const customizeSkipped = (target === 'customize' && state.coreMode);
        const isGated = (isForward && state.step === 'source' && !forwardOk) || customizeSkipped;
        if (isGated && !isActive) {
            btn.setAttribute('aria-disabled', 'true');
            if (customizeSkipped) {
                btn.removeAttribute('aria-describedby');
            } else {
                btn.setAttribute('aria-describedby', 'forward-nav-gate-reason');
            }
        } else {
            btn.removeAttribute('aria-disabled');
            btn.removeAttribute('aria-describedby');
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

// v1.0.9: forward-nav predicate. Shared between Next button (canAdvance) and
// the interactive breadcrumb (goToStep, added in Task 3). All four Source & paths
// fields are required on Step 1; once on Step 2 or Step 3 the user reached them
// via canMoveForward and forward-nav from there doesn't re-check (by construction).
function canMoveForward() {
    const sourceFilled  = !!(state.source  && state.source.trim());
    const editionFilled = state.edition !== null;
    const scratchFilled = !!(state.scratchDir && state.scratchDir.trim());
    const outputFilled  = !!(state.outputPath  && state.outputPath.trim());
    return sourceFilled && editionFilled && scratchFilled && outputFilled;
}

function updateNav() {
    document.getElementById('back-btn').disabled = state.step === 'source' || state.building || !!state.completed;
    document.getElementById('next-btn').disabled = !canAdvance() || state.building || !!state.completed;
}

function canAdvance() {
    if (state.step === 'source')    return canMoveForward();
    if (state.step === 'customize') return true;
    return false;
}

// v1.0.9: shared step-navigation entry point. Used by Back/Next buttons and
// interactive breadcrumb. forwardOnly callers (Next + forward breadcrumb)
// pass through canMoveForward; backward callers always succeed.
function goToStep(target, opts) {
    const isForward = STEP_ORDER.indexOf(target) > STEP_ORDER.indexOf(state.step);
    if (isForward && state.step === 'source' && !canMoveForward()) return;
    if (target === 'customize' && state.coreMode) return; // Customize is skipped in Core mode
    state.step = target;
    state.drilledCategory = null;
    renderStep();
    if (opts && opts.focusSelector) {
        // After render commits, focus the target field for edit-link UX (Task 5).
        const el = document.querySelector(opts.focusSelector);
        if (el && typeof el.focus === 'function') el.focus();
    }
}

const STEP_ORDER = ['source', 'customize', 'build'];

document.getElementById('back-btn').addEventListener('click', () => {
    if (state.step === 'customize') goToStep('source');
    else if (state.step === 'build') goToStep(state.coreMode ? 'source' : 'customize');
});
document.getElementById('next-btn').addEventListener('click', () => {
    if (state.step === 'source') goToStep(state.coreMode ? 'build' : 'customize');
    else if (state.step === 'customize') goToStep('build');
});

// v1.0.9: wire interactive breadcrumb buttons.
document.querySelectorAll('.crumb-btn').forEach(btn => {
    btn.addEventListener('click', () => {
        if (btn.getAttribute('aria-disabled') === 'true') return;
        const target = btn.dataset.step;
        if (target === state.step) return;
        goToStep(target);
    });
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

    const inlineStatus = renderInlineCleanupStatus();
    const outputMissing = !state.outputPath || !state.outputPath.trim();
    const buildDisabled = state.cleaning || (state.cleanupStatus && state.cleanupStatus.kind === 'error') || outputMissing;

    // When the user leaves the scratch directory blank on Step 1, scratchDir is null
    // and prefillOutputIfEmpty() never fires, leaving outputPath null. The Build ISO
    // script param -OutputIso has [ValidateNotNullOrEmpty()] and the pwsh subprocess
    // bombs at parameter binding with a confusing
    // ParameterArgumentValidationErrorEmptyStringNotAllowed before any UI feedback
    // surfaces. Guard the button + show an actionable warning so users know to fill
    // the output field in (we deliberately avoid silently auto-defaulting into the
    // user's Documents folder because dropping a multi-GB ISO there without intent
    // would be a worse surprise).
    const outputWarning = outputMissing
        ? el('div', { class: 'output-required-warning' },
            el('span', { class: 'output-required-glyph' }, '!'),
            el('span', { class: 'output-required-message' }, 'Choose an output location for the ISO file before building. (Scratch directory left blank is fine -- it lands in %TEMP% automatically -- but the output ISO needs an explicit path so you do not lose it.)')
          )
        : null;

    return el('section', { class: 'build' },
        el('h2', null, 'Ready to build'),
        inlineStatus,
        el('dl', null,
            el('dt', null, 'Source'),     el('dd', null, state.source || ''),
            el('dt', null, 'Edition'),    el('dd', null, editionLabel ? editionLabel.name : String(state.edition || '')),
            el('dt', null, 'Scratch'),    el('dd', null, state.scratchDir || ''),
            el('dt', null, 'Output ISO'),
            el('dd', { class: 'row' },
                el('input', {
                    id: 'out-input', type: 'text', value: state.outputPath || '',
                    onchange: e => { state.outputPath = e.target.value; state.outputPathIsAuto = false; renderStep(); }
                }),
                el('button', { onclick: () => ps({ type: 'browse-save-file', payload: { context: 'output', title: 'Save tiny11 ISO as...', filter: 'ISO files|*.iso|All files|*.*', defaultName: state.coreMode ? 'tiny11core.iso' : 'tiny11.iso' } }) }, 'Browse...')
            ),
            ...modeSummaryRows
        ),
        outputWarning,
        el('button', {
            class: 'primary',
            disabled: buildDisabled,
            title: outputMissing ? 'Set the Output ISO path first.' : null,
            onclick: () => {
                if (buildDisabled) return;
                state.building = true;
                // Reset cleanup state so a new run starts fresh. Mount/source
                // dirs get refreshed by the mount-state marker when install.wim
                // mounts in the new build.
                state.cleaning = false;
                state.cleanupStatus = null;
                state.pendingCleanupAfterCancel = false;
                state.mountActive = false;
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
                        installPostBootCleanup: state.installPostBootCleanup,
                        logBuildOutput: state.logBuildOutput,
                        appendLog: state.appendLog,
                        selections: state.selections,
                        coreMode: state.coreMode,
                        enableNet35: state.enableNet35,
                    },
                });
            }
        }, 'Build ISO')
    );
}

// Common cleanup command list, surfaced both in the recipe block (in-progress
// details panel) and the cancel/error screen's cleanup section.
//
// Order is load-bearing and mirrors tiny11-cancel-cleanup.ps1 (step 1 + step 2):
// the build pipeline `reg load`s the offline image's hives into HKLM\z* via
// Mount-Tiny11AllHives, and those stay loaded in the HOST OS even after the
// build process is Process.Kill-ed -- the System process holds NTUSER.DAT /
// SOFTWARE / SYSTEM / DEFAULT / COMPONENTS open INSIDE the mount dir until
// `reg unload` is called. If users skip these and jump straight to
// dism /Unmount-Image, DISM marches to 100% then errors with 0xc1420117
// ("directory could not be completely unmounted") because the hive files are
// still in use. C5h-iteration regression: 2026-05-12.
function buildCleanupCommands(mount, source) {
    return [
        '# Recovery sequence -- run ALL commands in order, top to bottom. Individual',
        '# lines may report errors; that is expected (the build was interrupted at',
        '# some unknown point, so some teardown steps will find "nothing to do").',
        '# The cumulative effect is recovery. Two specific quirks to expect:',
        '#',
        '#   reg unload  -- "ERROR: The parameter is incorrect."',
        '#       Windows quirk: reg.exe misreports "hive not loaded" as a parameter',
        '#       error. Means the build was cancelled before the hive-load phase --',
        '#       fine, nothing to unload. Keep going.',
        '#',
        '#   dism /Unmount-Image  -- "The request is not supported." or 0xc1420117',
        '#       Mount is in NeedsRemount/Invalid state, or files are still open',
        '#       inside it. The next command (/Cleanup-Mountpoints) clears stale',
        '#       registrations regardless. Keep going.',
        '#',
        '# Only the final two Remove-Item lines must succeed for recovery to be',
        '# complete; if they leave dirs on disk, reboot and retry.',
        '',
        'reg unload HKLM\\zCOMPONENTS',
        'reg unload HKLM\\zDEFAULT',
        'reg unload HKLM\\zNTUSER',
        'reg unload HKLM\\zSOFTWARE',
        'reg unload HKLM\\zSYSTEM',
        '',
        `dism /unmount-image /mountdir:"${mount}" /discard`,
        `dism /cleanup-mountpoints`,
        `takeown /F "${mount}" /R /D Y`,
        `icacls "${mount}" /grant Administrators:F /T /C`,
        `Remove-Item -Path "${mount}" -Recurse -Force -ErrorAction SilentlyContinue`,
        `Remove-Item -Path "${source}" -Recurse -Force -ErrorAction SilentlyContinue`,
    ];
}

// Cleanup spinner flow (2026-05-11): centralised dispatch. Sets the in-flight
// flag, primes the cleanupStatus row, navigates to Step 3 (renderBuild), then
// asks the launcher to spawn the cleanup script. The status row + Build ISO
// disable wiring lives in renderBuildStep / renderInlineCleanupStatus.
function startCleanupFlow() {
    if (!state.mountDir || !state.sourceDir) return;
    state.cleaning = true;
    state.cleanupStatus = { kind: 'progress', message: 'Starting cleanup…' };
    state.building = false;
    state.completed = null;
    state.step = 'build';
    renderStep();
    ps({ type: 'start-cleanup', payload: { mountDir: state.mountDir, sourceDir: state.sourceDir } });
}

// Two-step flow for mid-build "Cancel build & clean up": send cancel-build now,
// arm pendingCleanupAfterCancel so the build-error handler chains start-cleanup
// once the build subprocess has actually torn down (releasing DISM locks on
// the mount). Without this two-step, the cleanup script races a live DISM
// session and silently fails to delete the locked mount dir.
function cancelBuildAndCleanup() {
    if (state.cleaning || state.pendingCleanupAfterCancel) return;
    state.cleaning = true;
    state.pendingCleanupAfterCancel = true;
    state.cleanupStatus = { kind: 'progress', message: 'Cancelling build…' };
    renderStep();
    ps({ type: 'cancel-build', payload: {} });
}

// Recipe-only block (no button, no status) used in the in-progress details
// panel. The auto-cleanup button was removed from this context because:
//   1. renderProgress re-runs on every build-progress marker, so a status
//      line that toggles state.mountActive=false on cleanup-complete would
//      cause the whole block (including the success line) to vanish.
//   2. Clicking cleanup mid-build races the live DISM mount — the script's
//      Remove-Item silently fails because files are locked by the build PS
//      subprocess. The new "Cancel build & clean up" button in renderProgress
//      drives the cancel-then-cleanup chain instead.
function renderCleanupRecipe() {
    if (!state.mountActive) return null;
    const mount  = state.mountDir  || '';
    const source = state.sourceDir || '';
    if (!mount || !source) return null;
    const cmds = buildCleanupCommands(mount, source);
    return el('div', { class: 'core-cleanup' },
        el('p', { class: 'core-cleanup-intro' },
            '⚠ install.wim is currently mounted at the path below. If something goes wrong, click "Cancel build & clean up" above (preferred), or run these commands manually in an elevated PowerShell window:'
        ),
        el('pre', { class: 'cleanup-cmd' }, cmds.join('\n'))
    );
}

// Cleanup section for the build-error / build-cancelled screen. Has a button
// that triggers startCleanupFlow (which navigates to Step 3 + dispatches the
// PS script). Status is rendered in Step 3, not here — the user follows the
// spinner there.
function renderCleanupBlock() {
    if (!state.mountActive) return null;
    const mount  = state.mountDir  || '';
    const source = state.sourceDir || '';
    if (!mount || !source) return null;

    const cmds = buildCleanupCommands(mount, source);
    const tooltip = 'Runs the six cleanup commands automatically. WARNING: dism /cleanup-mountpoints clears the system-wide DISM mount-point cache — only click this if no other DISM operations are running on this machine.';

    const cleanupButton = el('button', {
        class: 'cleanup-warn-button',
        title: tooltip,
        disabled: state.cleaning,
        onclick: () => { if (!state.cleaning) startCleanupFlow(); },
    }, '⚠ Run cleanup automatically');

    return el('div', { class: 'core-cleanup' },
        el('p', { class: 'core-cleanup-intro' },
            '⚠ install.wim is currently mounted at the path below. Click the button to run cleanup automatically (you will be returned to the Build step where a spinner tracks progress), or run the commands in an elevated PowerShell window manually:'
        ),
        cleanupButton,
        el('p', { style: 'margin-top: 12px; font-size: 0.9em;' }, 'Manual fallback (run in elevated PowerShell):'),
        el('pre', { class: 'cleanup-cmd' }, cmds.join('\n'))
    );
}

// Inline cleanup-status row rendered at the top of renderBuildStep when a
// cleanup is in flight, just succeeded, or just failed. Three visual states:
//   - progress: spinner + message
//   - success:  green ✓ + message
//   - error:    red ✗ + message + "Retry cleanup" button
function renderInlineCleanupStatus() {
    const s = state.cleanupStatus;
    if (!s) return null;
    if (s.kind === 'progress') {
        return el('div', { class: 'cleanup-inline-status cleanup-inline-progress' },
            el('span', { class: 'wizard-spinner' }),
            el('span', { class: 'cleanup-inline-message' }, s.message)
        );
    }
    if (s.kind === 'success') {
        return el('div', { class: 'cleanup-inline-status cleanup-inline-success' },
            el('span', { class: 'cleanup-inline-glyph' }, '✓'),
            el('span', { class: 'cleanup-inline-message' }, s.message)
        );
    }
    return el('div', { class: 'cleanup-inline-status cleanup-inline-error' },
        el('span', { class: 'cleanup-inline-glyph' }, '✗'),
        el('span', { class: 'cleanup-inline-message' }, 'Cleanup failed: ' + s.message),
        el('button', {
            class: 'cleanup-retry-link',
            onclick: () => { if (!state.cleaning) startCleanupFlow(); }
        }, 'Retry cleanup')
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
        ? (state.fastBuild
            ? 'Core + Fast build (WinSxS wipe, /Compress:fast on selected edition, no recovery .esd — ~15–30 min faster, modestly larger ISO)'
            : 'Core (WinSxS wipe + /Compress:max + /Compress:recovery — smallest ISO, slowest build)')
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
            renderCleanupRecipe(),
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
            renderCleanupRecipe(),
          ];

    return el('section', { class: 'progress' },
        el('h2', null, 'Building tiny11 image...'),
        progressBar,
        el('p', null, `Phase: ${p.phase || '—'}`),
        el('p', null, `Step: ${p.step || '—'}`),
        el('div', { class: 'row cancel-row' },
            el('button', { onclick: () => ps({ type: 'cancel-build', payload: {} }) }, 'Cancel build'),
            el('button', {
                disabled: state.cleaning || !state.mountActive,
                title: state.mountActive
                    ? 'Cancel the in-progress build and then automatically clean the scratch mount + source directories.'
                    : 'Cleanup is only available once install.wim is mounted.',
                onclick: cancelBuildAndCleanup
            }, 'Cancel build & clean up'),
        ),
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

// Build-complete cleanup block. Simpler styling than renderCleanupBlock (no
// warning border) since the operation is safe by this point: install.wim is
// unmounted, the scratch subdirs are inert leftovers from the build, and the
// output ISO is the user's deliverable. Note explicitly tells the user the
// ISO is preserved; the PS script also enforces this as a script-side guard.
function renderCompletionCleanupBlock() {
    const mount  = state.mountDir  || '';
    const source = state.sourceDir || '';
    if (!mount || !source) return null;

    const tooltip = 'Deletes the temporary directories created during the build. The output ISO at the path above is preserved -- the script refuses to run if the ISO falls inside one of the cleanup targets.';

    const cleanupButton = el('button', {
        class: 'cleanup-button',
        title: tooltip,
        // v1.0.8 audit WARNING ui B3: use state.cleaning instead of the dead
        // state.cleanupRequested latch (never declared in state initializer;
        // never reset). state.cleaning is already managed by the cleanup flow.
        disabled: state.cleaning,
        style: 'padding: 8px 16px; border-radius: 4px; cursor: ' + (state.cleaning ? 'not-allowed' : 'pointer') + ';' + (state.cleaning ? ' opacity: 0.55;' : ''),
        onclick: () => {
            if (state.cleaning) return;
            state.cleaning = true;
            state.cleanupStatus = { kind: 'progress', message: 'Starting cleanup...' };
            ps({ type: 'start-cleanup', payload: {
                mountDir: mount,
                sourceDir: source,
                outputIso: state.outputPath || '',
            } });
            renderStep();
        },
    }, 'Clean up scratch directory');

    let statusEl = null;
    if (state.cleanupStatus) {
        // v1.0.8 audit WARNING ui B7: reuse theme-aware CSS classes instead
        // of duplicating colors with hardcoded hex. Layout-only properties
        // (margin-top, font-family, font-size) remain inline; colors and
        // font-weight come from .cleanup-status-success/-error (style.css).
        if (state.cleanupStatus.kind === 'progress') {
            statusEl = el('div', { class: 'cleanup-status', style: 'margin-top: 10px; font-family: monospace; font-size: 0.9em;' }, state.cleanupStatus.message);
        } else if (state.cleanupStatus.kind === 'success') {
            statusEl = el('div', { class: 'cleanup-status cleanup-status-success', style: 'margin-top: 10px; font-family: monospace; font-size: 0.9em;' }, '✓ ' + state.cleanupStatus.message);
        } else {
            statusEl = el('div', { class: 'cleanup-status cleanup-status-error', style: 'margin-top: 10px; font-family: monospace; font-size: 0.9em;' }, '✗ Cleanup failed: ' + state.cleanupStatus.message);
        }
    }

    return el('div', { class: 'completion-cleanup' },
        el('p', { style: 'margin: 0 0 8px 0;' },
            'Optional: remove temporary scratch directories used during the build. The output ISO at ',
            el('code', null, state.outputPath || '—'),
            ' will NOT be touched -- only the work subdirectories under the scratch root.'
        ),
        cleanupButton,
        statusEl
    );
}

function renderComplete() {
    const c = state.completed;
    return el('section', { class: 'complete' },
        el('h2', null, 'Build complete'),
        el('p', null, `Output: ${c.outputPath}`),
        el('button', { onclick: () => ps({ type: 'open-folder', payload: { path: c.outputPath } }) }, 'Open output folder'),
        el('button', { onclick: () => ps({ type: 'close', payload: {} }) }, 'Close'),
        renderCompletionCleanupBlock()
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
            tabindex: '0',
            role: 'button',
            onclick: () => { state.drilledCategory = c.id; renderStep(); },
            onkeydown: (ev) => {
                // v1.0.8 audit WARNING ui B1: Enter/Space activates focused card.
                if (ev.key === 'Enter' || ev.key === ' ') {
                    ev.preventDefault();
                    state.drilledCategory = c.id;
                    renderStep();
                }
            }
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
        // v1.0.8 audit WARNING ui B1: keyboard accessibility for clickable rows.
        // Locked rows remain mouse-only (no interaction anyway -- checkbox is
        // disabled). Clickable rows get tabindex/role/onkeydown to mirror the
        // existing onclick behavior under Enter/Space activation.
        const liOpts = r.locked ? { class: 'locked' } : {
            class: 'clickable',
            tabindex: '0',
            role: 'button',
            onclick: rowClickHandler,
            onkeydown: (ev) => {
                if (ev.key === 'Enter' || ev.key === ' ') {
                    ev.preventDefault();
                    rowClickHandler();
                }
            }
        };
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
        // v1.0.8 audit WARNING ui B1: keyboard accessibility for clickable rows.
        // Locked rows remain mouse-only (no interaction anyway -- checkbox is
        // disabled). Clickable rows get tabindex/role/onkeydown to mirror the
        // existing onclick behavior under Enter/Space activation.
        const liOpts = r.locked ? { class: 'locked' } : {
            class: 'clickable',
            tabindex: '0',
            role: 'button',
            onclick: rowClickHandler,
            onkeydown: (ev) => {
                if (ev.key === 'Enter' || ev.key === ' ') {
                    ev.preventDefault();
                    rowClickHandler();
                }
            }
        };
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

    // Fast-build hint (mode-aware copy preserved verbatim from v1.0.8).
    const fastBuildHint = state.coreMode
        ? 'In Core mode, swaps DISM /Export-Image /Compress:max for the much faster ' +
          '/Compress:fast (XPRESS) in Phase 20, and skips the /Compress:recovery esd ' +
          'export in Phase 22 entirely. Phase 20 still narrows install.wim to your ' +
          'selected edition (no edition prompt at install time). Saves roughly 15–30 ' +
          'minutes per Core build; output ISO is modestly larger. Recommended for VM ' +
          'testing and iterative Core builds.'
        : 'Skips DISM /Cleanup-Image and /Export-Image /Compress:recovery. ' +
          'Saves 25–40 minutes per build. With fast build the output ISO is typically ' +
          '7–8 GB; leaving fast build off enables recovery compression and shrinks the ' +
          'ISO by roughly 2 GB. Both produce functionally identical installs. Recommended ' +
          'for VM testing or iterative builds where ISO size doesn\'t matter.';

    // Core drawer (renders only when coreMode is on; expands inside right column).
    const coreDrawer = state.coreMode
        ? el('div', { class: 'core-drawer' },
            el('p', { style: 'margin: 0 0 8px 0;' },
                'tiny11 Core builds a significantly smaller image, but the output is not serviceable: ' +
                'you cannot install Windows Updates, add languages, or enable Windows features after install. ' +
                'Suitable for VM testing or short-lived development environments — not as a daily-driver Windows install.'),
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
            ))
        : null;

    // Left column: Source & paths card.
    const leftCard = el('div', { class: 'step1-card' },
        el('h4', null, 'Source & paths'),

        el('label', { for: 'src-input' }, 'Windows 11 ISO/DVD ', el('span', { class: 'req-asterisk', 'aria-hidden': 'true' }, '*')),
        el('div', { class: 'row' },
            el('input', {
                id: 'src-input', type: 'text', value: state.source || '',
                'aria-required': 'true',
                placeholder: 'ISO or drive letter where Windows 11 media is located (ex - E: or C:\\path\\win11.iso)',
                onchange: e => {
                    state.source = e.target.value;
                    state.editions = null;
                    state.edition = null;
                    ps({ type: 'validate-iso', payload: { path: state.source } });
                    startValidationSpinner();
                }
            }),
            el('button', { id: 'src-browse', onclick: () => ps({ type: 'browse-file', payload: { context: 'source', title: 'Select Win11 ISO', filter: 'ISO files|*.iso|All files|*.*' } }) }, 'Browse...')
        ),
        errorBanner,

        el('label', { for: 'edition-select' }, 'Edition ', el('span', { class: 'req-asterisk', 'aria-hidden': 'true' }, '*')),
        el('div', { class: 'row' },
            el('select', {
                id: 'edition-select',
                'aria-required': 'true',
                disabled: !state.editions,
                onchange: e => { state.edition = parseInt(e.target.value, 10); updateNav(); renderStep(); }
            }, editionsOptions),
            el('button', { class: 'browse-spacer', 'aria-hidden': 'true', tabindex: '-1' }, 'Browse...')
        ),
        el('div', { class: 'iso-status-line', role: 'status', 'aria-live': 'polite' },
            el('span', { class: 'iso-status-label' }, 'ISO/DVD state: '),
            state.validating ? el('span', { class: 'wizard-spinner', 'aria-hidden': 'true' }) : null,
            el('span', { id: 'iso-status-text', class: 'iso-status-value' }, computeIsoStatusText())
        ),

        el('label', { for: 'scratch-input' }, 'Scratch directory ', el('span', { class: 'req-asterisk', 'aria-hidden': 'true' }, '*')),
        el('div', { class: 'row' },
            el('input', {
                id: 'scratch-input', type: 'text', value: state.scratchDir || '',
                'aria-required': 'true',
                onchange: e => { state.scratchDir = e.target.value; prefillOutputIfEmpty(); renderStep(); }
            }),
            el('button', { onclick: () => ps({ type: 'browse-folder', payload: { context: 'scratch', title: 'Select scratch directory' } }) }, 'Browse...')
        ),

        el('label', { for: 'out-input' }, 'Output ISO ', el('span', { class: 'req-asterisk', 'aria-hidden': 'true' }, '*')),
        el('div', { class: 'row' },
            el('input', {
                id: 'out-input', type: 'text', value: state.outputPath || '',
                'aria-required': 'true',
                onchange: e => { state.outputPath = e.target.value; state.outputPathIsAuto = false; renderStep(); }
            }),
            el('button', { onclick: () => ps({ type: 'browse-save-file', payload: { context: 'output', title: 'Save tiny11 ISO as...', filter: 'ISO files|*.iso|All files|*.*', defaultName: state.coreMode ? 'tiny11core.iso' : 'tiny11.iso' } }) }, 'Browse...')
        )
    );

    // Right column: Build options card.
    const rightCard = el('div', { class: 'step1-card' },
        el('h4', null, 'Build options'),

        el('label', { class: 'checkbox-label' },
            el('input', {
                id: 'unmount-source', type: 'checkbox',
                checked: state.unmountSource,
                onchange: e => state.unmountSource = e.target.checked
            }),
            'Unmount source ISO/DVD when build finishes'
        ),

        el('label', { class: 'checkbox-label' },
            el('input', {
                id: 'fast-build', type: 'checkbox',
                checked: state.fastBuild,
                onchange: e => state.fastBuild = e.target.checked
            }),
            'Fast build (skip recovery compression)'
        ),
        el('p', { class: 'hint' }, fastBuildHint),

        el('label', { class: 'checkbox-label' },
            el('input', {
                id: 'install-post-boot-cleanup', type: 'checkbox',
                checked: state.installPostBootCleanup,
                onchange: e => state.installPostBootCleanup = e.target.checked
            }),
            'Install post-boot cleanup task'
        ),
        el('p', { class: 'hint' },
            'Re-removes apps and re-applies tweaks if Windows Update brings them back. ' +
            'Adds a scheduled task that fires 10 minutes after boot, daily at 03:00, ' +
            'and on every CU install. Tailored to your catalog selections; idempotent.'
        ),

        el('label', { class: 'checkbox-label' },
            el('input', {
                id: 'log-build-output', type: 'checkbox',
                checked: state.logBuildOutput,
                onchange: e => { state.logBuildOutput = e.target.checked; renderStep(); }
            }),
            'Log build output'
        ),
        el('label', { class: 'checkbox-label', style: 'margin-left: 1.75em;' },
            el('input', {
                id: 'append-log', type: 'checkbox',
                checked: state.appendLog,
                disabled: !state.logBuildOutput,
                onchange: e => state.appendLog = e.target.checked
            }),
            'Append to existing log'
        ),
        el('p', { class: 'hint' },
            'Writes the build progress to tiny11build.log alongside your scratch directory ' +
            '(or under %TEMP% when scratch is left blank). With "Append to existing log" off, ' +
            'each build overwrites the previous log; with it on, builds accumulate in one file.'
        ),

        // Core mode toggle relocated to bottom of right column. Drawer (warning +
        // .NET 3.5 + hint) expands within this card so left column never reflows.
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
        coreDrawer
    );

    return el('section', { class: 'form step1-grid' }, leftCard, rightCard);
}

onPs(msg => {
    const p = msg.payload || {};
    if (msg.type === 'iso-validated') {
        // v1.0.8 audit WARNING ui B4: drop stale validate-iso reply. User
        // retyped the path before this reply arrived; this is for an old
        // request. Filtering on p.path !== state.source uses the C#-side
        // path echo (IsoHandlers.cs:61) without needing a request-ID round-
        // trip. Residual edge case: typing A -> B -> A would re-accept A's
        // first reply, but the spinner-elapsed counter gives the user a
        // visual hint that something is off.
        if (p.path && p.path !== state.source) return;
        stopValidationSpinner();
        state.editions = p.editions;
        state.edition = (p.editions && p.editions[0] && p.editions[0].index) || null;
        state.source = p.path || state.source;
        renderStep();
    } else if (msg.type === 'iso-error') {
        stopValidationSpinner();
        renderStep();   // re-render to drop the spinner before the banner shows
        const banner = document.getElementById('src-error');
        if (banner) {
            banner.classList.remove('hidden');
            banner.textContent = p.message;
        }
    } else if (msg.type === 'browse-result') {
        if (!p.path) return; // user cancelled the dialog
        if (p.context === 'source')  { state.source = p.path; ps({ type: 'validate-iso', payload: { path: p.path } }); startValidationSpinner(); }
        else if (p.context === 'scratch') { state.scratchDir = p.path; prefillOutputIfEmpty(); renderStep(); }
        else if (p.context === 'output')  { state.outputPath = p.path; state.outputPathIsAuto = false; renderStep(); }
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
        // v1.0.8 audit WARNING ui B5: reset drill + search so the loaded
        // profile shows the category overview, not a stale drilled-in/search
        // view from before the load.
        state.search = '';
        state.drilledCategory = null;
        // v1.0.9: profile values for paths are explicit user choices —
        // future mode/scratch changes must NOT overwrite them.
        state.outputPathIsAuto = false;
        renderStep();
    }
});

// Extended onPs handler — Task 22 build-progress/complete/error + profile-saved + handler-error.
onPs(msg => {
    const p = msg.payload || {};
    if (msg.type === 'build-progress') {
        // mount-state markers carry mountActive / mountDir / sourceDir. They
        // also flow through state.progress so any UI element that watches
        // progress still works, but the dedicated fields are what
        // renderCleanupBlock reads to decide whether to show the button.
        if (p.phase === 'mount-state') {
            state.mountActive = (p.mountActive === true);
            if (p.mountActive === true) {
                if (p.mountDir)  state.mountDir  = p.mountDir;
                if (p.sourceDir) state.sourceDir = p.sourceDir;
            }
        }
        state.progress = p;
        renderStep();
    } else if (msg.type === 'build-complete') {
        state.building = false;
        state.completed = p;
        renderStep();
    } else if (msg.type === 'build-error') {
        state.building = false;
        // Chained "Cancel build & clean up": user clicked the chained button
        // mid-build, we sent cancel-build, the build subprocess is now down
        // and DISM mount locks are released. Now safe to fire start-cleanup.
        if (state.pendingCleanupAfterCancel) {
            state.pendingCleanupAfterCancel = false;
            state.cleanupStatus = { kind: 'progress', message: 'Starting cleanup…' };
            state.step = 'build';
            state.completed = null;
            renderStep();
            ps({ type: 'start-cleanup', payload: { mountDir: state.mountDir, sourceDir: state.sourceDir } });
            return;
        }
        const root = document.getElementById('content');
        clear(root);
        // Cancel-vs-failure header polish: BuildHandlers.cs emits build-error with
        // message "Build cancelled by user." when the user clicks plain "Cancel
        // build". Surface that as a friendlier "Build cancelled" header rather
        // than "Build failed" — same screen, less alarming.
        const wasCancelled = ((p.message || '') + '').toLowerCase().includes('cancelled by user');
        const children = [
            el('h2', null, wasCancelled ? 'Build cancelled' : 'Build failed'),
        ];
        if (!wasCancelled) {
            children.push(el('p', null, p.message || 'Unknown error'));
        }
        if (p.logPath) {
            children.push(el('p', { class: 'log-hint' }, 'Full build log: ', el('code', null, p.logPath)));
        }
        // Cleanup section renders for both Core and Worker; the function
        // self-gates on state.mountActive so it returns null outside the
        // mount window. The button on this screen navigates the user to
        // Step 3 (renderBuild) where the spinner-flow status row lives.
        const cleanupBlock = renderCleanupBlock();
        if (cleanupBlock) children.push(cleanupBlock);
        children.push(el('button', { onclick: () => ps({ type: 'close', payload: {} }) }, 'Close'));
        root.appendChild(el('section', { class: 'error' }, ...children));
    } else if (msg.type === 'cleanup-progress') {
        state.cleanupStatus = { kind: 'progress', message: `(${p.percent || 0}%) ${p.step || ''}` };
        renderStep();
    } else if (msg.type === 'cleanup-complete') {
        state.cleaning = false;
        state.cleanupStatus = { kind: 'success', message: p.message || 'Cleanup complete.' };
        state.mountActive = false;
        renderStep();
    } else if (msg.type === 'cleanup-error') {
        state.cleaning = false;
        state.cleanupStatus = { kind: 'error', message: p.message || 'Unknown cleanup error.' };
        renderStep();
    } else if (msg.type === 'cleanup-started') {
        // Acknowledgement that the handler accepted the request and spawned
        // pwsh. No UI change needed — cleanup-progress markers carry the
        // narrative from here.
    } else if (msg.type === 'profile-saved') {
        // v1: log only; future: transient toast.
        console.log('Profile saved:', p.path);
    } else if (msg.type === 'handler-error') {
        console.error('Handler error:', p.message);
        // If a cleanup or cancel-and-cleanup was in flight, surface to the UI
        // — otherwise a thrown handler (e.g. Process.Start) leaves the user
        // stuck on a "Starting cleanup…" spinner forever. The Retry cleanup
        // button on the error status row gives them a way out.
        if (state.cleaning || state.pendingCleanupAfterCancel) {
            state.cleaning = false;
            state.pendingCleanupAfterCancel = false;
            state.cleanupStatus = { kind: 'error', message: 'Cleanup handler failed: ' + (p.message || 'unknown') };
            renderStep();
        } else if (state.building) {
            // start-build was rejected by C# server-side guards (empty outputIso /
            // source, or some other handler-level failure) before the subprocess
            // spawned. The Build ISO onclick had already set state.building=true,
            // so we'd otherwise hang on the progress screen forever. Reset and
            // surface the message; client-side gates make this rare in practice
            // (defense in depth), so an alert is acceptable for v1.0.0 rather
            // than building a dedicated inline banner.
            state.building = false;
            renderStep();
            window.alert('Build could not start: ' + (p.message || 'unknown error'));
        }
    }
});

// Velopack update indicator — Task 25.
// update-available -> stash {version, changelog}, un-hide pulsing dot.
// Click -> showUpdateConfirmModal() (v1.0.8 B9: replaces confirm()) -> ps({type:'apply-update'}).
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
    // v1.0.8 audit WARNING ui B6: single consolidated boot handler. Pre-fix
    // there were TWO DOMContentLoaded handlers (one near line 1102 doing
    // initTheme/renderStep/__appVersion, one here wiring the update badge +
    // request-update-check). Both fired on the same event; boot order
    // depended on registration order. Now: explicit ordered sequence.
    initTheme();
    // v1.0.9: scratchDir is now boot-populated from __autoScratchPath; prefill
    // outputPath via the existing helper so the required-field gate is satisfied
    // out of the box.
    prefillOutputIfEmpty();

    // Wire update-badge click. Defensive: if the badge element is missing
    // (HTML refactor), skip badge wiring but still continue with renderStep
    // and request-update-check below.
    const badge = document.getElementById('update-badge');
    if (badge) {
        badge.addEventListener('click', () => {
            if (!pendingUpdate) return;
            // v1.0.8 audit WARNING ui B9: in-app modal replaces window.confirm
            // (which paused the WebView2 message pump for the modal's lifetime).
            showUpdateConfirmModal(pendingUpdate, () => {
                ps({ type: 'apply-update', payload: {} });
            });
        });
    }

    renderStep();

    const ver = document.getElementById('app-version');
    if (ver && typeof window.__appVersion === 'string') ver.textContent = window.__appVersion;

    // JS-initiated update-check handshake. C# UpdateHandlers receives this and
    // fires UpdateNotifier.CheckAsync; the response comes back as update-available
    // (or update-error) through the bridge. This guarantees the JS-side listener
    // is wired before C# sends, eliminating the post-Navigation race that hid
    // the badge in the prior smoke session.
    ps({ type: 'request-update-check', payload: {} });
});
