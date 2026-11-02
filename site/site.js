const current = location.pathname.split('/').pop() || 'index.html';
for (const link of document.querySelectorAll('nav a')) {
  if (link.getAttribute('href') === current) link.setAttribute('aria-current', 'page');
}
