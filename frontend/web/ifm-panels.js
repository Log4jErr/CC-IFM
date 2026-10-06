'use strict';

    // Panel pages: every panel is its own page and #panelNav switches between them, so a
    // list that grows in one panel can never push the controls of the panels below it
    // around any more. On a narrow screen the sidebar turns into a drawer that the IFM
    // button in the header opens.
    // "send" is deliberately not a page: the send list and the deliveries are the bottom
    // toolbar of the resources page (see web/ifm-resources.js).
    const PANEL_ORDER = ['processes', 'graph', 'resources', 'workers', 'peripherals',
        'filter', 'settings'];
    const PANEL_STORAGE = 'ifmPanel';
    let activePanel = null;

    function panelPages() {
        return Array.prototype.slice.call(document.querySelectorAll('#panelPages [data-panel-page]'));
    }

    function panelNavItems() {
        return Array.prototype.slice.call(document.querySelectorAll('#panelNav [data-panel]'));
    }

    // The page that is on screen ("send" is not one - see PANEL_ORDER): the send toolbar
    // of the resources page asks for it.
    function currentPanel() {
        return activePanel;
    }

    function savedPanelName() {
        try {
            const saved = localStorage.getItem(PANEL_STORAGE);
            if (saved && PANEL_ORDER.indexOf(saved) >= 0) return saved;
        } catch (err) {  }
        return PANEL_ORDER[0];
    }

    function showPanel(name, remember) {
        if (PANEL_ORDER.indexOf(name) < 0) name = PANEL_ORDER[0];
        activePanel = name;
        panelPages().forEach(function (page) {
            page.hidden = page.getAttribute('data-panel-page') !== name;
        });
        panelNavItems().forEach(function (item) {
            if (item.getAttribute('data-panel') === name) item.classList.add('active');
            else item.classList.remove('active');
        });
        if (remember) {
            try { localStorage.setItem(PANEL_STORAGE, name); } catch (err) {  }
        }
        closePanelNav();
        // The send toolbar belongs to the resources page; it follows every page switch.
        if (typeof refreshDeliveryPanelVisibility === 'function') refreshDeliveryPanelVisibility();
        // The page search boxes live in the fixed bottom toolbar: show the one that
        // belongs to the page that just came on screen.
        if (typeof refreshSearchToolbar === 'function') refreshSearchToolbar();
    }

    // The page-level search boxes are a fixed bottom toolbar (#searchToolbar): only
    // the group that belongs to the visible page is shown, so the search stays
    // reachable while a long list is scrolled instead of scrolling away with the
    // panel header.
    function refreshSearchToolbar() {
        const bar = el('searchToolbar');
        if (!bar) return;
        const panel = currentPanel();
        let any = false;
        Array.prototype.forEach.call(bar.querySelectorAll('[data-search-panel]'), function (wrap) {
            const show = wrap.getAttribute('data-search-panel') === panel;
            wrap.hidden = !show;
            if (show) any = true;
        });
        const want = any ? '' : 'none';
        if (bar.style.display !== want) bar.style.display = want;
        if (typeof syncBottomBars === 'function') syncBottomBars();
    }
    window.ifmRefreshSearchToolbar = refreshSearchToolbar;

    function panelNavOpen() {
        return document.body.classList.contains('nav-open');
    }

    function closePanelNav() {
        if (panelNavOpen()) document.body.classList.remove('nav-open');
    }

    function togglePanelNav() {
        document.body.classList.toggle('nav-open');
    }

    function navToggleVisible() {
        const node = el('navToggle');
        if (!node || typeof window.getComputedStyle !== 'function') return false;
        return window.getComputedStyle(node).display !== 'none';
    }

    // The header is sticky, so the sidebar has to start below it: the height travels as
    // a CSS variable instead of a fixed guess.
    function syncHeaderHeight() {
        const header = document.querySelector('.app-header');
        if (header) {
            document.documentElement.style.setProperty('--ifm-header-h', (header.offsetHeight || 0) + 'px');
        }
        // The fixed bottom bars (search toolbar, delivery panel) start to the right of
        // the sidebar: publish its width as a variable too, so they line up with the
        // page. In drawer mode (narrow screen) the sidebar is off canvas -> 0.
        syncNavWidth();
    }

    function syncNavWidth() {
        const nav = el('panelNav');
        const width = (nav && !navToggleVisible()) ? (nav.offsetWidth || 0) : 0;
        document.documentElement.style.setProperty('--ifm-nav-w', width + 'px');
    }

    function initPanelNav() {
        const nav = el('panelNav');
        if (!nav) {
            reportMissingElement('panelNav');
            return;
        }
        nav.addEventListener('click', function (event) {
            const item = event.target.closest('[data-panel]');
            if (item) showPanel(item.getAttribute('data-panel'), true);
        });
        const toggle = el('navToggle');
        if (toggle) {
            toggle.addEventListener('click', function (event) {
                event.preventDefault();
                togglePanelNav();
            });
        }
        const backdrop = el('navBackdrop');
        if (backdrop) backdrop.addEventListener('click', closePanelNav);
        document.addEventListener('keydown', function (event) {
            if (event.key === 'Escape') closePanelNav();
        });
        window.addEventListener('resize', function () {
            syncHeaderHeight();
            if (!navToggleVisible()) closePanelNav();
        });
        syncHeaderHeight();
        showPanel(savedPanelName(), false);
        window.setTimeout(syncHeaderHeight, 300);
    }
