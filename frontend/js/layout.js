// js/layout.js

const Layout = {
  render: function (activePage) {
    if (document.getElementById('sb')) return;
    const session = typeof Auth !== 'undefined' && Auth.getSession() ? Auth.getSession() : { first_name: 'User', role_name: 'Operator' };
    const initial = session.first_name ? session.first_name.charAt(0).toUpperCase() : 'U';
    const userName = session.first_name ? session.first_name.toLowerCase() : 'sysadmin';

    // Evaluate roles
    const roleName = session.role_name;
    const isSysAdmin = roleName === 'SysAdmin';
    const isOpto = roleName === 'Opto' || roleName === 'Optometrist';
    const isCoordinator = roleName === 'Coordinator';
    const isVolunteer = roleName === 'Volunteer';

    // Visibility Rules
    const showPatientReg = isSysAdmin || isVolunteer || isOpto;
    const showEyeExam = isSysAdmin || isVolunteer || isOpto || isCoordinator;
    const showInventory = isSysAdmin || isCoordinator;
    const showCampaign = isSysAdmin || isCoordinator;
    const showUser = isSysAdmin || isCoordinator;

    // Mobile CSS & Overlay Injection
    const styleHTML = `
    <style>
      /* Mobile Overlay Styling */
      .sb-overlay { display: none; position: fixed; inset: 0; top: var(--hh); z-index: 150; background: rgba(8,20,40,.35); backdrop-filter: blur(4px); -webkit-backdrop-filter: blur(4px); opacity: 0; transition: opacity var(--sp); }
      .sb-overlay.active { display: block; opacity: 1; }
      
      @media (max-width: 768px) {
        /* Fix Main Layout - prevent squeezing */
        .main { margin-left: 0 !important; padding: 20px 15px !important; }
        .main.col { margin-left: 0 !important; }
        
        /* Adjust Header for small screens */
        .hbrand { width: auto !important; border-right: none !important; padding: 0 10px !important; }
        .logo-text { display: none !important; } /* Hide text to save space */
        
        /* Off-canvas Sidebar */
        .sb { transform: translateX(-100%); transition: transform var(--sp) var(--ease); width: var(--sb-w) !important; box-shadow: var(--shl); }
        .sb.col { transform: translateX(-100%); }
        .sb.mobile-open { transform: translateX(0); }
        
        /* Body lock and blur */
        body.sb-mobile-active { overflow: hidden; }
        body.sb-mobile-active .main { filter: blur(3px); pointer-events: none; }
      }
      
      /* Alert Box Consistency Fixes */
      .alert-box.show { display: flex !important; }
      .alert-box svg { display: inline-block !important; flex-shrink: 0 !important; }
    </style>`;

    const headerHTML = `
    <header class="hdr">
      <a class="hbrand" id="hbrand" href="#">
        <div class="logo-mark">
          <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="var(--navy)" stroke-width="2.5" stroke-linecap="round"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/></svg>
        </div>
        <div class="logo-text" id="logo-text">
          <div class="l1">iCare <span>Brighter Future</span></div>
          <div class="l2">Foundation</div>
        </div>
      </a>
      <button class="hdr-tog" onclick="Layout.toggleSidebar()" title="Toggle sidebar">
        <svg width="19" height="19" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><line x1="3" y1="12" x2="21" y2="12"/><line x1="3" y1="6" x2="21" y2="6"/><line x1="3" y1="18" x2="21" y2="18"/></svg>
      </button>
      <div class="hdr-r">
        <div class="hdr-user">
          <div class="hdr-av">${initial}</div>
          <span>${userName}</span>
        </div>
        <button class="btn-lo" onclick="Auth.logout()">
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><polyline points="16 17 21 12 16 7"/><line x1="21" y1="12" x2="9" y2="12"/></svg>
          <span style="display:none; @media(min-width:480px){display:inline;}">Logout</span>
        </button>
      </div>
    </header>`;

    const overlayHTML = `<div class="sb-overlay" id="sb-overlay" onclick="Layout.toggleSidebar()"></div>`;

    const sidebarHTML = `
    <aside class="sb" id="sb">
      <div class="sb-srch">
        <div class="sb-sw">
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/></svg>
          <input type="text" placeholder="Search menu&hellip;" oninput="Layout.filterMenu(this.value)">
        </div>
      </div>
      <nav id="sb-nav">
        ${showPatientReg ? `
        <a class="ni ${activePage === 'patient' ? 'active' : ''}" href="patient_registration.html">
          <span class="nico"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/></svg></span>
          <span class="nl">Patient Registration</span>
        </a>` : ''}
        
        ${showEyeExam ? `
        <a class="ni ${activePage === 'eye_exam' ? 'active' : ''}" href="eye_exam.html">
          <span class="nico"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="3"/><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/></svg></span>
          <span class="nl">Eye Exam</span>
        </a>` : ''}
        
        ${showInventory ? `
        <a class="ni ${activePage === 'inventory' ? 'active' : ''}" href="inventory_management.html">
          <span class="nico"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"></path><polyline points="3.27 6.96 12 12.01 20.73 6.96"></polyline><line x1="12" y1="22.08" x2="12" y2="12"></line></svg></span>
          <span class="nl">Inventory Management</span>
        </a>` : ''}

        ${showCampaign ? `
        <a class="ni ${activePage === 'campaigns' ? 'active' : ''}" href="campaign_management.html">
          <span class="nico"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><rect x="3" y="4" width="18" height="18" rx="2"/><line x1="16" y1="2" x2="16" y2="6"/><line x1="8" y1="2" x2="8" y2="6"/><line x1="3" y1="10" x2="21" y2="10"/></svg></span>
          <span class="nl">Campaign Management</span>
        </a>` : ''}
        
        ${showUser ? `
        <a class="ni ${activePage === 'user' ? 'active' : ''}" href="user_registration.html">
          <span class="nico"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg></span>
          <span class="nl">User Registration</span>
        </a>` : ''}
      </nav>
    </aside>`;

    const footerHTML = `<footer class="ftr"><span>&copy; 2026</span><strong>iCare Brighter Future Foundation</strong><span>&middot; All rights reserved</span></footer>`;

    // Inject styles and HTML
    document.head.insertAdjacentHTML('beforeend', styleHTML);
    document.body.insertAdjacentHTML('afterbegin', headerHTML + overlayHTML + sidebarHTML);
    document.body.insertAdjacentHTML('beforeend', footerHTML);
  },

  toggleSidebar: () => {
    // Determine screen width context
    if (window.innerWidth <= 768) {
      // Mobile Overlay Logic
      const sb = document.getElementById('sb');
      const overlay = document.getElementById('sb-overlay');
      const isOpen = sb.classList.contains('mobile-open');

      sb.classList.toggle('mobile-open', !isOpen);
      overlay.classList.toggle('active', !isOpen);
      document.body.classList.toggle('sb-mobile-active', !isOpen);
    } else {
      // Standard Desktop Collapse Logic
      let sbc = document.getElementById('sb').classList.contains('col');
      sbc = !sbc;
      document.getElementById('sb').classList.toggle('col', sbc);
      document.getElementById('main').classList.toggle('col', sbc);
      document.getElementById('hbrand').style.width = sbc ? '56px' : 'var(--sb-w)';
      document.getElementById('logo-text').style.display = sbc ? 'none' : '';
    }
  },

  filterMenu: (query) => {
    const q = query.toLowerCase();
    const links = document.querySelectorAll('#sb-nav a.ni');
    links.forEach(link => {
      const text = link.textContent.toLowerCase();
      link.style.display = text.includes(q) ? 'flex' : 'none';
    });
  }
};

// Global hooks for scroll reset, alert display, and input constraints
document.addEventListener('DOMContentLoaded', () => {
  // MutationObserver to reset scroll positions of modals when opened
  const observer = new MutationObserver((mutations) => {
    mutations.forEach((mutation) => {
      if (mutation.type === 'attributes' && mutation.attributeName === 'class') {
        const target = mutation.target;
        if (target.classList.contains('overlay') && target.classList.contains('open')) {
          target.querySelectorAll('.mbody, .modal, .preview-table-container').forEach(el => {
            el.scrollTop = 0;
          });
        }
      }
    });
  });

  observer.observe(document.body, {
    attributes: true,
    subtree: true,
    attributeFilter: ['class']
  });

  // Global keydown handler to prevent exponents (e, E) in SPH/CYL fields
  document.addEventListener('keydown', (e) => {
    const target = e.target;
    if (target && target.tagName === 'INPUT' && target.type === 'number') {
      const id = (target.id || '').toLowerCase();
      if (id.includes('sph') || id.includes('cyl')) {
        if (e.key === 'e' || e.key === 'E') {
          e.preventDefault();
        }
      }
    }
  });

  // Setup SPH/CYL input validations
  const setupSphCylInputs = () => {
    document.querySelectorAll('input').forEach(input => {
      const id = (input.id || '').toLowerCase();
      if (id.includes('sph') || id.includes('cyl')) {
        if (input.type === 'number') {
          input.type = 'text';
        }
        input.setAttribute('inputmode', 'decimal');

        input.addEventListener('input', function () {
          const originalVal = this.value;
          const selectionStart = this.selectionStart;
          const selectionEnd = this.selectionEnd;

          let cleaned = '';
          for (let i = 0; i < originalVal.length; i++) {
            const char = originalVal[i];
            if (i === 0 && (char === '+' || char === '-')) {
              cleaned += char;
            } else if (char >= '0' && char <= '9') {
              cleaned += char;
            } else if (char === '.' && !cleaned.includes('.')) {
              cleaned += char;
            }
          }

          if (cleaned !== originalVal) {
            this.value = cleaned;
            const diff = originalVal.length - cleaned.length;
            try {
              this.setSelectionRange(selectionStart - diff, selectionEnd - diff);
            } catch (err) {
              // ignore
            }
          }
        });
      }
    });
  };
  setupSphCylInputs();
});
