# Place all the behaviors and hooks related to the matching controller here.
# All this logic will automatically be available in application.js.
# You can use CoffeeScript in this file: http://coffeescript.org/
$ ->
  current_page = $('body').data('controller')
  $("#main_nav > li[id='#{current_page}']").addClass('active')
