// js/app-config.js

const API_BASE = 'https://dev.icarebrighterfuture.org/api';

const Auth = {
  // Saves user data to session and calculates the correct coordinator ID
  setSession: (data) => {
    const effectiveCoordinatorId = (data.role_name === 'Coordinator')
      ? data.id
      : data.coordinator_id;

    data.effectiveCoordinatorId = effectiveCoordinatorId;
    sessionStorage.setItem('userSession', JSON.stringify(data));
  },

  // Retrieves the full session object
  getSession: () => {
    const session = sessionStorage.getItem('userSession');
    return session ? JSON.parse(session) : null;
  },

  // Retrieves just the isolation ID for API calls
  getEffectiveCoordinatorId: () => {
    const session = Auth.getSession();
    return session ? session.effectiveCoordinatorId : null;
  },

  // Protects pages from unauthorized access
  checkAuth: () => {
    if (!sessionStorage.getItem('userSession')) {
      window.location.href = 'login.html';
    }
  },

  // Clears session and redirects
  logout: () => {
    sessionStorage.removeItem('userSession');
    window.location.href = 'login.html';
  }
};
/*document.addEventListener('DOMContentLoaded', () => {
  document.querySelectorAll('input[type="date"]').forEach(input => {

    const hint = document.createElement('small');
    hint.className = 'date-hint';
    hint.textContent = 'DD-MM-YYYY';

    input.insertAdjacentElement('afterend', hint);
  });
});*/