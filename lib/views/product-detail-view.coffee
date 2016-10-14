{$, $$, $$$, View} = require 'atom-space-pen-views'
_ = require 'lodash'
util = require 'util'

module.exports =
class ProductDetailView extends View
  initialize: ({@imdoneRepo, @path, @uri, @connectorManager}) ->

  updateConnectorForEdit: (product) ->
    _.set product, 'connector', {} unless product.connector
    return unless product.name == 'github' && !_.get(product, 'connector.config.repoURL')
    _.set product, 'connector.config.repoURL', @connectorManager.getGitOrigin() || ''

  handleEvents: (@emitter)->
    return if @initialized || !@emitter
    @initialized = true
    # @on 'click', '#create-tasks', =>
    #   @emitter.emit 'tasks.create', @product.name
    @emitter.on 'project.removed', (project) =>
      @$configEditor.empty()
      @configEditor.destroy() if @configEditor
      delete @product

    @emitter.on 'product.selected', (product) =>
      return unless product
      @updateConnectorForEdit product
      @setProduct product

    @connectorManager.on 'product.linked', (product) =>
      return unless product
      @updateConnectorForEdit product
      @setProduct product

    @connectorManager.on 'product.unlinked', (product) =>
      return unless product
      # READY: Connector plugin should be removed
      @updateConnectorForEdit product
      @setProduct product

    @emitter.on 'connector.changed', (product) =>
      return unless product
      @updateConnectorForEdit product
      @setProduct product


  @content: (params) ->
    require 'json-editor'
    @div class: 'product-detail-view-content config-container', =>
      @div class: 'json-editor-container', =>
        @div outlet: '$configEditor', class: 'json-editor native-key-bindings'

  setProduct: (@product)->
    return unless @product && @product.name
    @$configEditor.empty()
    return unless @product.linked
    @createEditor()

  createEditor: ->
    options =
      schema: @product.schemas.config # TODO: Rule schemas to be set by GET /projects/ :projectId/products +rules-workflow
      startval: @product.connector.config # TODO: Rule values to be set by GET /projects/ :projectId/products +rules
      theme: 'bootstrap3'
      required_by_default: true
      disable_edit_json: true
      disable_properties: true
      disable_collapse: true
      disable_array_delete_last_row: true
      disable_array_delete_all_rows: true

    # TODO: Add provider configurations before creating editor
    @configEditor.destroy() if @configEditor
    if @product.isEnabled() then @$configEditor.show() else @$configEditor.hide()
    @configEditor = new JSONEditor @$configEditor.get(0), options
    @configEditor.on 'change', => @emitChange()
    @$configEditor.find('input').first().focus()

  emitChange: ->
    editorVal = @configEditor.getValue()
    currentVal =  _.get @product, 'connector.config'
    return unless @product.isEnabled()
    return if _.isEqual editorVal, currentVal
    _.set @product, 'connector.config', editorVal
    _.set @product, 'connector.name', @product.name unless _.get @product, "connector.name"
    connector = _.cloneDeep @product.connector
    @connectorManager.saveConnector connector, (err, connector) =>
      # TODO: Handle errors by unauthenticating if needed and show login with error
      throw err if err
      @product.connector = connector
      @setProduct @product
      @emitter.emit 'connector.changed', @product
