request = require 'superagent'
noCache = require 'superagent-no-cache'
async = require 'async'
authUtil = require './auth-util'
{Emitter} = require 'atom'
{allowUnsafeEval} = require 'loophole'
Pusher = allowUnsafeEval -> require 'pusher-js'
_ = require 'lodash'
Task = require 'imdone-core/lib/task'
config = require '../../config'
helper = require './imdone-helper'
debug = require('debug/browser')
pluginManager = require './plugin-manager'
log = debug 'imdone-atom:client'
# localStorage.debug = 'imdone-atom:client'

# READY: The client public_key, secret and pusherKey should be configurable id:26
PROJECT_ID_NOT_VALID_ERR = new Error "Project ID not valid"
NO_RESPONSE_ERR = new Error "No response from imdone.io"
USER_NOT_FOUND_ERR = new Error "User not found"
baseUrl = config.baseUrl # READY: This should be set to localhost if process.env.IMDONE_ENV = /dev/i id:27
baseAPIUrl = "#{baseUrl}/api/1.0"
accountUrl = "#{baseAPIUrl}/account"
projectsUrl = "#{baseUrl}/account/projects"
plansUrl = "#{baseUrl}/plans"
pusherAuthUrl = "#{baseUrl}/pusher/auth"
githubAuthUrl = "#{baseUrl}/auth/github"

Pusherlog = debug 'imdone-atom:pusher'

module.exports =
class ImdoneioClient extends Emitter
  @PROJECT_ID_NOT_VALID_ERR: PROJECT_ID_NOT_VALID_ERR
  @USER_NOT_FOUND_ERR: USER_NOT_FOUND_ERR
  @baseUrl: baseUrl
  @baseAPIUrl: baseAPIUrl
  @projectsUrl: projectsUrl
  @plansUrl: plansUrl
  @githubAuthUrl: githubAuthUrl
  authenticated: false
  connectionAccepted: false
  authRetryCount: 0

  constructor: () ->
    super
    test = () => @connectionAccepted || @authenticated
    async.until test,
      (cb) =>
        setTimeout () =>
          @authFromStorage (err) =>
            if err == USER_NOT_FOUND_ERR
              @connectionAccepted = true
              @emit 'unauthenticated'
              return cb err
            if err && @connectionAccepted
              @emit 'unauthenticated'
              return cb err
            cb()
        , 2000

  setHeaders: (req) ->
    log 'setHeaders:begin'
    withHeaders = req.set('Date', (new Date()).getTime())
      .set('Accept', 'application/json')
      .set('Authorization', authUtil.getAuth(req, "imdone", @email, @password, config.imdoneKeyB, config.imdoneKeyA))
      .timeout 30000
      .use noCache
      .on 'error', (err) =>
        #console.log "Error on request to imdone.io:", err
        if err.code == 'ECONNREFUSED' && @authenticated
          @emit 'unavailable'
          delete @authenticated
          delete @user

    log 'setHeaders:end'
    withHeaders

  # TODO: If we get a forbidden error, then emit auth failure id:28
  doGet: (path) ->
    @setHeaders request.get("#{baseAPIUrl}#{path || ''}")

  doPost: (path) ->
    @setHeaders request.post("#{baseAPIUrl}#{path}")

  doPatch: (path) ->
    @setHeaders request.patch("#{baseAPIUrl}#{path}")

  doPut: (path) ->
    @setHeaders request.put("#{baseAPIUrl}#{path}")

  _auth: (cb) ->
    process.nextTick () =>
      return cb null, @user if @user
      @authenticating = true
      @getAccount (err, user) =>
        err = user.err if user && user.err
        return @onAuthFailure err, null, cb if err
        @user = user
        return @onAuthFailure new Error('User is null'), null, cb if !user or !user.profile
        @onAuthSuccess user, cb
        delete @authenticating

  logoff: ->
    @removeCredentials (err) =>
      return if err
      @authenticated = false
      delete @password
      delete @email
      delete @user
      @emit 'unauthenticated'

  authFromStorage: (cb) ->
    cb = (() ->) unless cb
    # return cb new Error("Auth from stoage failed") if @storageAuthFailed
    return cb null, @user if @user
    @loadCredentials (err) =>
      return cb err if err
      @_auth (err, user) =>
        log "Authentication err:", err if err
        # @storageAuthFailed = _.get err, 'imdone_status'
        # TODO: if err.status == 404 we should show an error id:29
        cb err, user

  onAuthSuccess: (user, cb) ->
    return cb null, user if @authenticated
    @authenticated = true
    @authRetryCount = 0
    @emit 'authenticated'
    pluginManager.init()
    @saveCredentials (err) =>
      @storageAuthFailed = false
      cb(null, user)
      log 'onAuthSuccess'
      @handlePushEvents()

  onAuthFailure: (err, res, cb) ->
    # READY: Add imdone_status to the Error id:30
    status = err.imdone_status = if err && (err.code == 'ECONNREFUSED' || _.get(err, 'response.err.status') == 404) then 'unavailable' else 'failed'
    @connectionAccepted = true unless status == "unavailable"
    @authenticated = false
    @emit 'authentication-failed',
      retries: @authRetryCount
      status: status
    @authRetryCount++
    delete @password
    delete @email
    cb(err, res)

  authenticate: (@email, password, cb) ->
    log 'authenticate:start'
    @password = authUtil.sha password
    @_auth cb

  isAuthenticated: () -> @authenticated

  handlePushEvents: () ->
    @pusher = new Pusher config.pusherKey,
      encrypted: true
      authEndpoint: pusherAuthUrl
      disableStats: true
    # READY: imdoneio pusher channel needs to be configurable id:31
    @pusherChannel = @pusher.subscribe "#{config.pusherChannelPrefix}-#{@user.id}"
    @pusherChannel.bind 'product.linked', (data) => @emit 'product.linked', data
    @pusherChannel.bind 'product.unlinked', (data) => @emit 'product.unlinked', data
    @pusherChannel.bind 'connector.enabled', (data) => @emit 'connector.enabled', data
    @pusherChannel.bind 'connector.disabled', (data) => @emit 'connector.disabled', data
    @pusherChannel.bind 'connector.changed', (data) => @emit 'connector.changed', data
    @pusherChannel.bind 'connector.created', (data) => @emit 'connector.created', data

    log 'handlePushEvents'

  saveCredentials: (cb) ->
    @removeCredentials (err) =>
      log 'saveCredentials'
      return cb err if (err)
      key = authUtil.toBase64("#{@email}:#{@password}")
      @db().insert key: key, cb

  loadCredentials: (cb) ->
    @db().findOne {}, (err, doc) =>
      return cb err if err
      return cb USER_NOT_FOUND_ERR unless doc
      parts = authUtil.fromBase64(doc.key).split(':')
      @email = parts[0]
      @password = parts[1]
      cb null

  removeCredentials: (cb) -> @db().remove {}, { multi: true }, cb

  # API methods -------------------------------------------------------------------------------------------------------
  inviteToProject: (repo, invited) ->
    @doPost("/projects/")

  getProducts: (projectId, cb) ->
    # READY: Implement getProducts id:32
    @doGet("/projects/#{projectId}/products").end (err, res) =>
      return cb(err, res) if err || !res.ok
      cb(null, res.body)

  getAccount: (cb) ->
    log 'getAccount:start'
    @doGet("/account").end (err, res) =>
      log 'getAccount:end'
      return cb(err, res) if err || !res.ok
      cb(null, res.body)

  getProject: (projectId, cb) ->
    # READY: Implement getProject id:33
    @doGet("/projects/#{projectId}").end (err, res) =>
      return cb(NO_RESPONSE_ERR) unless res
      return cb(PROJECT_ID_NOT_VALID_ERR) if err && err.status == 404
      return cb(PROJECT_ID_NOT_VALID_ERR) if res.body && res.body.kind == "ObjectId" && res.body.name == "CastError"
      return cb err if err
      cb null, res.body

  updateProject: (project, cb) ->
    @doPatch("/projects/#{project.id}").send(project).end (err, res) =>
      return cb(err, res) if err || !res.ok
      cb(null, res.body)

  updateTaskOrder: (projectId, order, cb) ->
    @doPut("/projects/#{projectId}/order").send(order).end (err, res) =>
      return cb(err, res) if err || !res.ok
      cb(null, res.body)

  getIssue: (connector, number, cb) ->
    # TODO: We have to be better about communicating errors from connector api response such as insufficient permissions with github gh:116 id:34
    @doGet("/projects/#{connector._project}/connectors/#{connector.id}/issues/#{number}").end (err, res) =>
      return cb(err, res) if err || !res.ok
      cb(null, res.body)

  findIssues: (connector, query, cb) ->
    @doGet("/projects/#{connector._project}/connectors/#{connector.id}/issues/search/?q=#{query}").end (err, res) =>
      return cb(err, res) if err || !res.ok
      cb(null, res.body)

  newIssue: (connector, issue, cb) ->
    @doPost("/projects/#{connector._project}/connectors/#{connector.id}/issues").send(issue).end (err, res) =>
      return cb(err, res) if err || !res.ok
      cb(null, res.body)

  createConnector: (repo, connector, cb) ->
    projectId = @getProjectId repo
    return cb "project must have a sync.id to connect" unless projectId
    # READY: Implement createProject id:35
    @doPost("/projects/#{projectId}/connectors").send(connector).end (err, res) =>
      return cb(err, res) if err || !res.ok
      cb(null, res.body)

  updateConnector: (repo, connector, cb) ->
    projectId = @getProjectId repo
    return cb "project must have a sync.id to connect" unless projectId
    # READY: Implement createProject id:36
    @doPatch("/projects/#{projectId}/connectors/#{connector.id}").send(connector).end (err, res) =>
      return cb(err, res) if err || !res.ok
      cb(null, res.body)

  enableConnector: (repo, connector, cb) ->
    @_connectorAction repo, connector, "enable", cb

  disableConnector: (repo, connector, cb) ->
    @_connectorAction repo, connector, "disable", cb

  _connectorAction: (repo, connector, action, cb) ->
    projectId = @getProjectId repo
    return cb "project must have a sync.id to connect" unless projectId
    @doPost("/projects/#{projectId}/connectors/#{connector.id}/#{action}").end (err, res) =>
      return cb(err, res) if err || !res.ok
      cb(null, res.body)

  createProject: (repo, cb) ->
    process.nextTick () =>
      @doPost("/projects").send(
        name: repo.getDisplayName()
        localConfig: repo.config.toJSON()
      ).end (err, res) =>
        return cb(err, res) if err || !res.ok
        project = res.body
        @setProjectId repo, project.id
        @setProjectName repo, project.name
        @setSortConfig repo
        repo.saveConfig (err) => cb err, project
  getProjectId: (repo) ->  _.get repo, 'config.sync.id'
  setProjectId: (repo, id) -> _.set repo, 'config.sync.id', id
  setSortConfig: (repo) ->
    _.set repo, 'config.sync.useImdoneioForPriority', true
    _.set repo, 'config.keepEmptyPriority', true
  getProjectName: (repo) -> _.get repo, 'config.sync.name'
  setProjectName: (repo, name) -> _.set repo, 'config.sync.name', name

  # READY: Send branch on sync if available for rules. gh:135 +now id:37
  syncTasks: (repo, tasks, cb) ->
    gitRepo = helper.repoForPath repo.getPath()
    projectId = @getProjectId repo
    chunks = _.chunk tasks, 10
    modifiedTasks = []
    total = 0
    log "Sending #{tasks.length} tasks to imdone.io"
    repo.emit 'sync.percent', 0
    async.eachOfLimit chunks, 2, (chunk, i, cb) =>
      log "Sending chunk of #{chunk.length} tasks to imdone.io"
      data =
        tasks: chunk
        branch: gitRepo && gitRepo.branch
      setTimeout () => # Not sure why, but this sometimes hangs without using setTimeout
        @doPost("/projects/#{projectId}/tasks").send(data).end (err, res) =>
          #console.log "Received Sync Response #{i} err:#{err}"
          if err && err.code == 'ECONNREFUSED' && @authenticated
            #console.log "Error on syncing tasks with imdone.io", err
            @emit 'unavailable'
            delete @authenticated
            delete @user
          return cb err if err
          data = res.body
          modifiedTasks.push data
          total += data.length
          repo.emit 'sync.percent', Math.ceil(total/tasks.length*100)
          log "Received #{total} tasks from imdone.io"
          cb()
        log "Chunk of #{chunk.length} tasks sent to imdone.io"
      ,10
    , (err) ->
      cb err, _.flatten modifiedTasks

  db: (collection) ->
    path = require 'path'
    collection = path.join.apply @, arguments if arguments.length > 1
    collection = "config" unless collection
    @datastore = {} unless @datastore
    return @datastore[collection] unless !@datastore[collection]
    DataStore = require('nedb')
    @datastore[collection] = new DataStore
      filename: path.join atom.getConfigDirPath(), 'storage', 'imdone-atom', collection
      autoload: true
    @datastore[collection]

  tasksDb: (repo) ->
    #READY: return the project specific task DB id:38
    @db 'tasks',repo.getPath().replace(/\//g, '_')

  listsDb: (repo) ->
    #READY: return the project specific task DB id:39
    @db 'lists',repo.getPath().replace(/\//g, '_')

  @instance: new ImdoneioClient
