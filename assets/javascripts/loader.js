$(document).ready(function(){
  $('.dup').parent().parent().each(function() {this.style.backgroundColor = "rgb(255, 190, 190)"});
});

function toggleCheckboxesSelection(el) {
  var klass = $(el).parents().find('a').attr('class')
  var boxes = $(el).parents('form').find('input.' + klass + '[type=checkbox]');
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

function clearDates(el) {
  if(confirm("This action will clear all dates in this column. Proceed?"))
  {
    var klass = $(el).parents().find('a').attr('class')
    var dates = $(el).parents('form').find('input.' + klass + '[type=date]');
    dates.each(function(){
      $(this).val('');
    });
  }
  else
  {
  }
}
