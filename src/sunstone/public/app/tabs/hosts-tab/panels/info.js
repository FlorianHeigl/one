define(function(require) {
  /*
    DEPENDENCIES
   */
  
  var Locale = require('utils/locale');
  var Humanize = require('utils/humanize');
  var RenameTr = require('utils/panel/rename-tr');
  var TemplateTable = require('utils/panel/template-table');
  var PermissionsTable = require('utils/panel/permissions-table');
  var ClusterTr = require('utils/panel/cluster-tr');
  var OpenNebulaHost = require('opennebula/host');
  var CPUBars = require('../utils/cpu-bars');
  var MemoryBars = require('../utils/memory-bars');

  /*
    TEMPLATES
   */
  
  var TemplateInfo = require('hbs!./info/html');

  /*
    CONSTANTS
   */
  
  var TAB_ID = require('../tabId');
  var PANEL_ID = require('./info/panelId');
  var RESOURCE = "Host"

  /*
    CONSTRUCTOR
   */

  function Panel(info) {
    var that = this;
    that.title = Locale.tr("Info");
    that.icon = "fa-info-circle";

    that.element = info[RESOURCE.toUpperCase()];

    // Check if any of the existing VMs in the Host define the IMPORT_TEMPLATE
    //  attribute to be imported into OpenNebula.
    that.canImportWilds = false;
    if (that.element.TEMPLATE.VM) {
      var vms = that.element.TEMPLATE.VM;
      if (!$.isArray(vms)) { // If only 1 VM convert to array
        vms = [vms];
      }
      $.each(vms, function() {
        if (this.IMPORT_TEMPLATE) {
          that.canImportWilds = true;
          return false;
        }
      });
    }

    // Hide information of the Wild VMs of the Host and the ESX Hosts
    //  in the template table. Unshow values are stored in the unshownTemplate
    //  object to be used when the host info is updated.
    that.unshownTemplate = {};
    that.strippedTemplate = {};
    var unshownKeys = ['HOST', 'VM', 'WILDS'];
    $.each(that.element.TEMPLATE, function(key, value) {
      if ($.inArray(key, unshownKeys) > -1) {
        that.unshownTemplate[key] = value;
      } else {
        that.strippedTemplate[key] = value;
      }
    });

    return this;
  };

  Panel.PANEL_ID = PANEL_ID;
  Panel.prototype.html = _html;
  Panel.prototype.setup = _setup;

  return Panel;

  /*
    FUNCTION DEFINITIONS
   */

  function _html() {
    var templateTableHTML = TemplateTable.html(
                                      this.strippedTemplate, 
                                      RESOURCE, 
                                      Locale.tr("Attributes"));

    var renameTrHTML = RenameTr.html(RESOURCE, this.element.NAME);
    var clusterTrHTML = ClusterTr.html(this.element.CLUSTER);
    var permissionsTableHTML = PermissionsTable.html(TAB_ID, RESOURCE, this.element);
    var cpuBars = CPUBars.html(this.element);
    var memoryBars = MemoryBars.html(this.element);
    var stateStr = Locale.tr(OpenNebulaHost.stateStr(this.element.STATE));

    return TemplateInfo({
      'element': this.element,
      'renameTrHTML': renameTrHTML,
      'clusterTrHTML': clusterTrHTML,
      'templateTableHTML': templateTableHTML,
      'permissionsTableHTML': permissionsTableHTML,
      'cpuBars': cpuBars,
      'memoryBars': memoryBars,
      'stateStr': stateStr,
    });
  }

  function _setup(context) {
    RenameTr.setup(RESOURCE, this.element.ID, context);
    ClusterTr.setup(RESOURCE, this.element.ID, this.element.CLUSTER_ID, context);
    TemplateTable.setup(this.strippedTemplate, RESOURCE, this.element.ID, context, this.unshownTemplate);
    PermissionsTable.setup(TAB_ID, RESOURCE, this.element, context);
    return false;
  }
});