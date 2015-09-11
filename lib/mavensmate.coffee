{$, $$, $$$, View}    = require 'atom-space-pen-views'
window.jQuery         = $
fs                    = require 'fs'
path                  = require 'path'
{exec}                = require 'child_process'
{Subscriber,Emitter}  = require 'emissary'
EventEmitter          = require('./emitter').pubsub
CoreAdapter           = require('./adapter')
ProjectListView       = require './project-list-view'
PanelView             = require('./panel/panel-view').panel
StatusBarView         = require './status-bar-view'
LogFetcher            = require './log-fetcher'
tracker               = require('./promise-tracker').tracker
util                  = require './util'
emitter               = require('./emitter').pubsub
commands              = require './commands.json'
ErrorsView            = require './errors-view'
atom.mavensmate       = {}
AtomWatcher           = require('./watchers/atom-watcher').watcher

require '../scripts/bootstrap'

module.exports =

  class MavensMate
    self = @
    Subscriber.includeInto this

    editorSubscription: null
    apexAutocompleteRegistration: null
    vfAutocompleteRegistration: null

    panel: null # mavensmate status panel
    mavensmateAdapter: null
    errorsView: null

    errorsDeserializer:
      name: 'ErrorsView'
      version: 1
      deserialize: (state) ->
        self.createErrorsView(state) if state.constructor is Object

    constructor: ->
      console.log 'Creating new instance of MavensMate plugin...'
      
      # temporary hack to workaround cert issues introduced by chrome 39
      # (https://github.com/joeferraro/MavensMate-Atom/issues/129#issuecomment-69847533)
      process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0'
      
      # initiate mavensmate for this atom workspace
      @init()

    # Activates the package, instantiates the views, etc.
    init: ->
      self = @

      self.mavensmateAdapter = CoreAdapter

      self.panel = PanelView
      self.registerApplicationCommands()
      
      console.log 'DOIIIING ITTTT'
      console.log atom.project
      console.log atom.project.getPaths()
      
      # if this window is an atom project AND a mavensmate project, initialize the project
      if atom.project? and atom.project.getPaths().length > 0 and util.hasMavensMateProjectStructure()
        self.mavensmateAdapter.initialize()
          .then(() ->
            # TODO
            # atom.commands.add 'atom-workspace', 'mavensmate:open-project', => self.openProject()
            if not atom.workspace.mavensMateProjectInitialized
              self.initializeProject()
          )
          .catch((err) ->
            self.panel.addPanelViewItem(err, 'danger')
            self.panel.toggle()
          )

      atom.project.onDidChangePaths => @onProjectPathChanged()

    # todo: expose settings retrieval from core so we can display this list
    # openProject: ->
    #   @selectList = new ProjectListView()
    #   @selectList.show()

    createErrorsView: (params) ->
      @errorsView = new ErrorsView(params)

    onProjectPathChanged: ->
      if util.hasMavensMateProjectStructure() and not atom.workspace.mavensMateProjectInitialized
        @initializeProject()
      else
        console.log('not a mavensmate project or already initialized')

    initializeProject: ->
      self = @
      self.panel.addPanelViewItem('Initializing MavensMate, please wait...', 'info')

      atom.project.mavensmateId = util.fileBodyAsString(path.join(atom.project.getPaths()[0], 'config', '.settings'), true).id
      atom.workspace.mavensMateProjectInitialized ?= true

      # TODO: use atom.project.getPaths()
      atom.project.mavensMateErrors = {}
      atom.project.mavensMateCheckpointCount = 0
      
      # instantiate mavensmate panel, show it
      self.panel.toggle()

      console.log 'initializing project --> '+atom.project.getPaths()
            
      # attach MavensMate views/handlers to each present and future workspace editor views
      atom.workspace.observeTextEditors (editor) ->
        self.handleBufferEvents editor
        self.registerGrammars editor

      # instantiate client interface
      self.registerProjectCommands()

      # places mavensmate 3 dot icon in the status bar
      @mavensmateStatusBar = new StatusBarView(self.panel)
      
      self.createErrorsView(util.uris.errorsView)
      atom.workspace.addOpener (uri) ->
        self.errorsView if uri is util.uris.errorsView

      atom.deserializers.add(self.errorsDeserializer)

      atom.commands.add 'atom-workspace', 'mavensmate:view-errors', ->
        atom.workspace.open(util.uris.errorsView)

      # attach commands
      atom.commands.add 'atom-workspace', 'mavensmate:toggle-output', ->
        self.panel.toggleView()

      # deletes file(s) from server
      atom.commands.add 'atom-workspace', 'mavensmate:delete-file-from-server', ->
        treeView = util.treeView()
        if treeView.hasFocus() # clicked in sidebar
          filePaths = treeView.selectedPaths()
        else # command palette or right click in editor
          filePaths = [util.activeFile()]
        params =
          command: 'delete-metadata'
          commandDefinition: 
            coreName: 'delete-metadata'
            atomName: 'delete-metadata'
            panelMessage: 'Deleting'
            scope: 'project'
          args:
            pane: atom.workspace.getActivePane()
          payload:
            paths: filePaths
        fileString = (filePaths.map (path) -> util.baseName(path)).join(', ')
        answer = atom.confirm
          message: "Are you sure you want to delete #{fileString} from Salesforce?"
          # NB: specs expects the following buton indices, 0: Cancel, 1: Delete
          #     so that we can simulate button clicks properly in the spec
          buttons: ["Cancel", "Delete"]
        if answer == 1 # 1 => Delete
          self.mavensmateAdapter.executeCommand(params)
            .then (result) ->
              self.adapterResponseHandler(params, result)
            .catch (err) ->
              self.adapterResponseHandler(params, err)

      self.panel.addPanelViewItem('MavensMate initialized successfully. Happy coding!', 'success')

    registerApplicationCommands: ->
      for c in util.getCommands('application')
        resolvedName = 'mavensmate:' + c.atomName

        atom.commands.add 'atom-workspace', resolvedName, (options) ->
          commandName = options.type.split(':').pop()
          cmd = util.getCommandByAtomName(commandName)

          params =
            command: cmd.coreName
            commandDefinition: cmd
            args:
              pane: atom.workspace.getActivePane()

          payload = {}
          payload.args = {}

          if 'ui' of cmd
            payload.args.ui = cmd.ui

          if Object.keys(payload).length != 0
            params.payload = payload

          self.mavensmateAdapter.executeCommand(params)
            .then (result) ->
              self.adapterResponseHandler(params, result)
            .catch (err) ->
              self.adapterResponseHandler(params, err)

    registerProjectCommands: ->
      # attach commands to workspace based on commands.json
      for c in util.getCommands('project')
        resolvedName = 'mavensmate:' + c.atomName
        
        atom.commands.add 'atom-workspace', resolvedName, (options) ->
          commandName = options.type.split(':').pop()
          cmd = util.getCommandByAtomName(commandName)

          params =
            command: cmd.coreName
            commandDefinition: cmd
            args:
              pane: atom.workspace.getActivePane()

          payload = {}
          payload.args = {}
          
          if 'ui' of cmd
            payload.args.ui = cmd.ui
          if 'paths' of cmd
            switch cmd['paths']
              when 'active'
                payload.paths = [util.activeFile()]
              when 'selected'
                payload.paths = util.getSelectedFiles()
          if 'classes' of cmd
            switch cmd['classes']
              when 'activeBaseName'
                if util.activeFile().indexOf('.cls') >= 0
                  payload.classes = [util.activeFileBaseName().split('.')[0]]
          if 'payloadMetadata' of cmd
            payload.metadataType = cmd.payloadMetadata
          
          if Object.keys(payload).length != 0
            params.payload = payload

          answer = 0
          if cmd.confirm?
            answer = atom.confirm
              message: cmd.confirm.message
              detailedMessage: cmd.confirm.detailedMessage
              buttons: cmd.confirm.buttons
          if answer == 0 # Yes
            self.mavensmateAdapter.executeCommand(params)
              .then (result) ->
                self.adapterResponseHandler(params, result)
              .catch (err) ->
                self.adapterResponseHandler(params, err)

    adapterResponseHandler: (params, result) ->
      tracker.pop(result.promiseId).result
      EventEmitter.emit 'mavensmate:promise-completed', result.promiseId
      EventEmitter.emit 'mavensmate:panel-notify-finish', params, result, result.promiseId

    # ensures custom extensions load the correct atom grammar file
    # TODO: refactor
    registerGrammars: (editor) ->
      self = @
      buffer = editor.getBuffer()
      if buffer.file?
        ext = path.extname(buffer.file.path)
        if ext == '.auradoc' || ext == '.app' || ext == '.evt' || ext == '.cmp' || ext == '.object'
          editor.setGrammar atom.syntax.grammarForScopeName('text.xml')

    # watches active editors for events like save
    handleBufferEvents: (editor) ->
      self = @
      buffer = editor.getBuffer()
      if buffer.file? and util.isMetadata(buffer.file.path) and atom.config.get('MavensMate-Atom').mm_compile_on_save
        editor.onDidSave () ->
          params =
            command: 'compile-metadata'
            commandDefinition: 
              coreName: 'compile-metadata'
              atomName: 'compile-metadata'
              panelMessage: 'Compiling'
              scope: 'project'
            args:
              pane: atom.workspace.getActivePane()
              textEditor: atom.workspace.getActiveTextEditor()
              buffer: buffer
            payload:
              paths: [buffer.file.path]
          self.mavensmateAdapter.executeCommand(params)
            .then (result) ->
              self.adapterResponseHandler(params, result)
            .catch (err) ->
              self.adapterResponseHandler(params, err)

    # Deactivate the package and destroy the mavensmate views.
    destroy: ->
      # remove MavensMate items from the status bar
      @mavensmateStatusBar?.destroy()
      @mavensmateStatusBar = null

      # remove the MavensMate panel
      if panel?
        @panel.destroy()
        @panel = null

      #unsubscribe from all listeners
      @unsubscribe()