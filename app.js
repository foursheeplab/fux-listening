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
