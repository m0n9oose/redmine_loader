$(document).ready(function(){
  $('.dup').parent().parent().each(function() {this.style.backgroundColor = "rgb(255, 190, 190)"});
  $(".other-formats")[0].style.display = "none"
});

function toggleIssuesSelection(el) {
  var boxes = $(el).parents('form').find('input[type=checkbox]');
  var all_checked = true;
  boxes.each(function(){ if (!$(this).attr('checked')) { all_checked = false; } });
  boxes.each(function(){
    if (all_checked) {
      $(this).removeAttr('checked');
    } else if (!$(this).attr('checked')) {
      $(this).attr('checked', true);
    }
  });
}
