const players = [...document.querySelectorAll('audio')];
players.forEach(player => player.addEventListener('play', () => {
  players.forEach(other => { if (other !== player) other.pause(); });
}));
document.querySelectorAll('select[data-player]').forEach(select => {
  select.addEventListener('change', () => {
    const player = document.getElementById(select.dataset.player);
    player.pause();
    player.src = select.value;
    player.load();
  });
});

// Preserve links shared before the book's own numbering replaced the old anchors.
function redirectLegacyScoreLink() {
  const match = location.hash.match(/^#fig-(\d+)$/);
  if (!match) return;
  const oldNumber = Number(match[1]);
  if (oldNumber >= 4 && oldNumber <= 23) {
    location.replace(`#score-${oldNumber - 3}`);
  }
}
window.addEventListener('hashchange', redirectLegacyScoreLink);
redirectLegacyScoreLink();
