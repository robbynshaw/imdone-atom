{$, $$, $$$, View, TextEditorView} = require 'atom-space-pen-views'
{Emitter} = require 'atom'
_ = require 'lodash'
util = require 'util'
debug = require 'debug/browser'
config = require '../../config'
log = debug 'imdone-atom:project-settings-view'
Client = require '../services/imdoneio-client'
require('bootstrap-tokenfield') $

module.exports =
class ProjectSettingsView extends View
  @content: (params) ->
    @div =>
      @div outlet:'disabledProject', class:'block text-center' , =>
        @h1 "Welcome to #{config.name}!"
        @h3 "Create and Update GitHub issues from TODO comments in your code!"
        @button outlet:'enableProjectBtn', click:'enableProject', class:'btn btn-lg btn-success', "Use #{config.name} with this project"
        @div outlet:'progressContainer', class:'block', style:'display:none;', =>
          @progress outlet:'progress', class:'inline-block', max:'100'
          @div outlet: 'progressValue', class: 'inline-block'
          @div class: 'block', =>
            @span outlet:'progressText'
      @div outlet: 'settingsPanel', style:'display:none;', =>
        # @h1 "Project Settings"

        # READY: Add config view here
        # @h1 "Configuration (.imdone/config.json)"
      @div id:'disable-project-link', outlet:'enabledProject', class: 'pull-right highlight-error', style:'display:none;', =>
        @a click:'disableProject', class:'inline-block', "Stop using imdone.io with this project"

  initialize: ({@imdoneRepo, @path, @uri, @connectorManager}) ->
    @client = Client.instance

  handleEvents: (@emitter) ->
    if @initialized || !@emitter then return else @initialized = true
    @emitter.on 'sync.percent', (val) =>
      @progress.attr 'value', val
      @progressValue.html "#{val}%"
    @emitter.on 'project.found', (project) =>
      @updateProgress 0
      @settingsPanel.show()
      @disabledProject.hide()
      @enabledProject.show()

    @emitter.on 'project.removed', (project) =>
      @settingsPanel.hide()
      @enabledProject.hide()
      @enableProjectBtn.show()
      @disabledProject.show()

  updateProgress: (n) ->
    return @progressContainer.hide() if n == 0
    n ?= ''
    @progressText.html "Syncing #{n} Comments.  Please wait..."
    @progress.attr 'value', null
    @progressValue.html ''
    @progressContainer.show()

  enableProject: (e) ->
    @emitter.emit 'error.hide'
    @startTime = new Date().getTime()
    @updateProgress @imdoneRepo.getTasks().length
    @enableProjectBtn.hide()
    @client.createProject @imdoneRepo, (err, project) =>
      if _.get(err,'response.body.name') == "TOO_MANY_PROJECTS_ERROR"
        @emitter.emit 'error', @$tooManyProjectsMsg()
        @enableProjectBtn.show()
        @disabledProject.show()
        @updateProgress 0
      return if err
      return unless project
      @imdoneRepo.checkForIIOProject()

  $tooManyProjectsMsg: ->
    projectUrl = Client.projectsUrl
    $$ ->
      @p =>
        @span "You'll have to "
        @a href:"#{Client.plansUrl}", "upgrade"
        @span " or "
        @a href:"#{Client.projectsUrl}", "disable/remove projects"
        @span " before adding another."

  disableProject: (e) ->
    @imdoneRepo.disableProject() if window.confirm "Do you really want to stop using imdone.io with #{@imdoneRepo.getProjectName()}?"
