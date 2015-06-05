{-------------------------------------------------------------------------------
   Copyright 2012 Ethea S.r.l.

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
-------------------------------------------------------------------------------}

unit Kitto.Ext.GridPanel;

{$I Kitto.Defines.inc}

interface

uses
  ExtPascal, Ext, ExtData, ExtForm, ExtGrid, ExtPascalUtils, ExtUxGrid,
  EF.ObserverIntf, EF.Types, EF.Tree,
  Kitto.Metadata.Views, Kitto.Metadata.DataView, Kitto.Store, Kitto.Types,
  Kitto.Ext.Base, Kitto.Ext.Controller, Kitto.Ext.DataPanelLeaf, Kitto.Ext.Editors;

type
  TKExtGridPanel = class(TKExtDataPanelLeafController)
  strict private
    FEditorGridPanel: TExtGridEditorGridPanel;
    FGridView: TExtGridGridView;
    FPagingToolbar: TExtPagingToolbar;
    FPageRecordCount: Integer;
    FSelectionModel: TExtGridRowSelectionModel;
    FInplaceEditing: Boolean;
    function GetGroupingFieldName: string;
    function CreatePagingToolbar: TExtPagingToolbar;
    procedure InitGridColumns;
    function GetRowColorPatterns(out AFieldName: string): TEFPairs;
    procedure CreateGridView;
    procedure CheckGroupColumn;
    procedure InitColumnEditors(const ARecord: TKViewTableRecord);
    procedure SetGridColumnEditor(const AEditorManager: TKExtEditorManager;
      const AViewField: TKViewField; const ALayoutNode: TEFNode; const AColumn: TExtGridColumn);
  private
    FConfirmButton: TKExtButton;
    FCancelButton: TKExtButton;
    FClientStoreOnLoadSet: Boolean;
    function GetConfirmJSCode(const AMethod: TExtProcedure): string;
    function GetBeforeEditJSCode(const AMethod: TExtProcedure): string;
    procedure ShowConfirmButtons(const AShow: Boolean);
  strict protected
    procedure ExecuteNamedAction(const AActionName: string); override;
    function GetOrderByClause: string; override;
    procedure InitDefaults; override;
    procedure SetViewTable(const AValue: TKViewTable); override;
    function CreateClientStore: TExtDataStore; override;
    procedure AfterCreateTopToolbar; override;
    procedure AddTopToolbarToolViewButtons; override;
    function GetSelectConfirmCall(const AMessage: string;
      const AMethod: TExtProcedure): string; override;
    function AddActionButton(const AUniqueId: string; const AView: TKView;
      const AToolbar: TKExtToolbar): TKExtActionButton; override;
    function GetSelectCall(const AMethod: TExtProcedure): TExtFunction; override;
    function IsMultiSelect: Boolean; override;
    function GetDefaultRemoteSort: Boolean; override;
    function GetIsPaged: Boolean;
    function IsActionVisible(const AActionName: string): Boolean; override;
    function IsActionSupported(const AActionName: string): Boolean; override;
  public
    procedure UpdateObserver(const ASubject: IEFSubject; const AContext: string = ''); override;
    procedure AfterConstruction; override;
    procedure Activate; override;
  published
    procedure LoadData; override;
    procedure SelectionChanged;
    procedure UpdateField;
    procedure BeforeEdit;
    procedure ConfirmInplaceChanges;
    procedure CancelInplaceChanges;
    procedure ConfirmLookup;
    procedure CancelLookup;
  end;

implementation

uses
  SysUtils, StrUtils, Math, Types,
  superobject,
  EF.StrUtils, EF.Localization, EF.JSON, EF.Macros,
  Kitto.Metadata.Models, Kitto.Rules, Kitto.AccessControl, Kitto.Config,
  Kitto.Ext.Session, Kitto.Ext.Utils;

{ TKExtGridPanel }

function TKExtGridPanel.GetOrderByClause: string;
var
  LSortFieldNames: TStringDynArray;
  LGroupingFieldName: string;
  I: Integer;
begin
  LSortFieldNames := ViewTable.GetStringArray('Controller/Grouping/SortFieldNames');
  if Length(LSortFieldNames) = 0 then
  begin
    LGroupingFieldName := GetGroupingFieldName;
    if LGroupingFieldName <> '' then
      Result := ViewTable.FieldByName(GetGroupingFieldName).QualifiedDBNameOrExpression
    else
      Result := inherited GetOrderByClause;
  end
  else
  begin
    for I := Low(LSortFieldNames) to High(LSortFieldNames) do
      LSortFieldNames[I] := ViewTable.FieldByName(LSortFieldNames[I]).QualifiedDBNameOrExpression;
    Result := Join(LSortFieldNames, ', ');
  end;
end;

function TKExtGridPanel.GetGroupingFieldName: string;
begin
  Result := ViewTable.GetExpandedString('Controller/Grouping/FieldName');
end;

function TKExtGridPanel.GetIsPaged: Boolean;
begin
  Assert(Assigned(ViewTable));

  Result := ViewTable.GetBoolean('Controller/PagingTools', ViewTable.Model.IsLarge);
end;

procedure TKExtGridPanel.AfterConstruction;
begin
  inherited;
  FClientStoreOnLoadSet := False;
end;

procedure TKExtGridPanel.AfterCreateTopToolbar;
var
  LAnyButtonsRequiringSelection: Boolean;
  LServerSideSelectionChangeNeeded: Boolean;
begin
  inherited;
  LAnyButtonsRequiringSelection := FButtonsRequiringSelection.Count > 0;
  // Server-side selectionchange notifcation is expensive - enable only if
  // strictly necessary.
  LServerSideSelectionChangeNeeded := False;//FInplaceEditing;

  // Note: the selectionchange handler must be called in afterrender as well
  // to account for the first row, which is selected by default.
  if LAnyButtonsRequiringSelection then
  begin
    FSelectionModel.On('selectionchange', JSFunction('s', GetRowButtonsDisableJS));
    On('afterrender', JSFunction(Format('var s = %s;', [FSelectionModel.JSName]) + GetRowButtonsDisableJS));
  end;

  if LServerSideSelectionChangeNeeded then
  begin
    FSelectionModel.On('selectionchange', GetSelectCall(SelectionChanged));
    On('afterrender', GetSelectCall(SelectionChanged));
  end;
end;

procedure TKExtGridPanel.BeforeEdit;
var
  LReqBody: ISuperObject;
begin
  LReqBody := SO(Session.RequestBody);
  InitColumnEditors(ServerStore.GetRecord(LReqBody.O['data'], Session.Config.UserFormatSettings));

  ShowConfirmButtons(True);
end;

function TKExtGridPanel.CreateClientStore: TExtDataStore;
var
  LGroupingFieldName: string;
  LGroupingMenu: Boolean;
begin
  LGroupingFieldName := GetGroupingFieldName;
  LGroupingMenu := ViewTable.GetBoolean('Controller/Grouping/EnableMenu');
  if (LGroupingFieldName <> '') or LGroupingMenu then
  begin
    if ViewTable.FindField(LGroupingFieldName) = nil then
      raise Exception.CreateFmt('Field %s not found. Cannot group.', [LGroupingFieldName]);
    Result := TExtDataGroupingStore.Create(Self);
    Result.Url := MethodURI(GetRecordPage);
    //TExtDataGroupingStore(Result).GroupOnSort := True;
    if LGroupingFieldName <> '' then
    begin
      TExtDataGroupingStore(Result).GroupField := LGroupingFieldName;
      Result.RemoteSort := True;
    end;
  end
  else
    Result := inherited CreateClientStore;
  FEditorGridPanel.Store := Result;
end;

procedure TKExtGridPanel.CreateGridView;
var
  LGroupingMenu: Boolean;
  LCountTemplate: string;
  LGroupingFieldName: string;
  LRowClassProvider: string;
  LRowColorPatterns: TEFPairs;
  LRowColorFieldName: string;
begin
  { TODO : investigate the row body feature }
  LGroupingFieldName := GetGroupingFieldName;
  LGroupingMenu := ViewTable.GetBoolean('Controller/Grouping/EnableMenu');
  if (LGroupingFieldName <> '') or LGroupingMenu then
  begin
    FGridView := TExtGridGroupingView.Create(Self);
    TExtGridGroupingView(FGridView).EmptyGroupText := _('No data to display in this group.');
    TExtGridGroupingView(FGridView).StartCollapsed := ViewTable.GetBoolean('Controller/Grouping/StartCollapsed');
    TExtGridGroupingView(FGridView).EnableGroupingMenu := LGroupingMenu;
    TExtGridGroupingView(FGridView).EnableNoGroups := LGroupingMenu;
    TExtGridGroupingView(FGridView).HideGroupedColumn := True;
    TExtGridGroupingView(FGridView).ShowGroupName := ViewTable.GetBoolean('Controller/Grouping/ShowName');
    if ViewTable.GetBoolean('Controller/Grouping/ShowCount') then
    begin
      LCountTemplate := ViewTable.GetString('Controller/Grouping/ShowCount/Template',
        '{text} ({[values.rs.length]} {[values.rs.length > 1 ? "%ITEMS%" : "%ITEM%"]})');
      LCountTemplate := _(LCountTemplate);
      LCountTemplate := ReplaceText(LCountTemplate, '%ITEMS%',
        _(ViewTable.GetString('Controller/Grouping/ShowCount/PluralItemName', ViewTable.PluralDisplayLabel)));
      LCountTemplate := ReplaceText(LCountTemplate, '%ITEM%',
        _(ViewTable.GetString('Controller/Grouping/ShowCount/ItemName', ViewTable.DisplayLabel)));
      TExtGridGroupingView(FGridView).GroupTextTpl := LCountTemplate;
    end;
  end
  else
    FGridView := TExtGridGridView.Create(Self);
  FGridView.EmptyText := _('No data to display.');
  FGridView.EnableRowBody := True;
  { TODO : make ForceFit configurable? }
  //FGridView.ForceFit := False;
  LRowClassProvider := ViewTable.GetExpandedString('Controller/RowClassProvider');
  if LRowClassProvider <> '' then
    FGridView.GetRowClass :=  FGridView.JSFunctionInLine(LRowClassProvider)
  else
  begin
    LRowColorPatterns := GetRowColorPatterns(LRowColorFieldName);
    if Length(LRowColorPatterns) > 0 then
      FGridView.SetCustomConfigItem('getRowClass',
        [JSFunction('r', Format('return getColorStyleRuleForRecordField(r, ''%s'', [%s]);',
          [LRowColorFieldName, PairsToJSON(LRowColorPatterns)])), True]);
  end;
  FEditorGridPanel.View := FGridView;
end;

procedure TKExtGridPanel.InitDefaults;
begin
  inherited;
  FEditorGridPanel := TExtGridEditorGridPanel.CreateAndAddTo(Items);
  FEditorGridPanel.Border := False;
  FEditorGridPanel.Header := False;
  FEditorGridPanel.Region := rgCenter;
  FSelectionModel := TExtGridRowSelectionModel.Create(FEditorGridPanel);
  FSelectionModel.Grid := FEditorGridPanel;
  FEditorGridPanel.SelModel := FSelectionModel;
  FEditorGridPanel.StripeRows := True;
  FEditorGridPanel.Frame := False;
  FEditorGridPanel.AutoScroll := True;
  FEditorGridPanel.AutoWidth := True;
  FEditorGridPanel.ColumnLines := True;
  FEditorGridPanel.TrackMouseOver := True;
  FEditorGridPanel.EnableHdMenu := False;
end;

function TKExtGridPanel.IsActionSupported(const AActionName: string): Boolean;
begin
  Result := True;
end;

function TKExtGridPanel.IsActionVisible(const AActionName: string): Boolean;
begin
  Result := inherited IsActionVisible(AActionName);
  if Result and SameText(AActionName, 'Edit') then
    Result := not FInplaceEditing;
end;

function TKExtGridPanel.IsMultiSelect: Boolean;
begin
  Assert(Assigned(FSelectionModel));

  Result := not FSelectionModel.SingleSelect;
end;

procedure TKExtGridPanel.SetGridColumnEditor(const AEditorManager: TKExtEditorManager;
  const AViewField: TKViewField; const ALayoutNode: TEFNode; const AColumn: TExtGridColumn);
var
  LEditable: boolean;
  LIsReadOnlyNode: TEFNode;
  LEditor: TExtFormField;
  LSubject: IEFSubject;
begin
  Assert(Assigned(AEditorManager));

  if Assigned(ALayoutNode) then
  begin
    LIsReadOnlyNode := ALayoutNode.FindNode('IsReadOnly');
    if Assigned(LIsReadOnlyNode) then
      LEditable := not LIsReadOnlyNode.AsBoolean
    else
      LEditable := FInplaceEditing and not AViewField.IsReadOnly;
  end
  else
    LEditable := FInplaceEditing and not AViewField.IsReadOnly;

  LEditable := LEditable and AViewField.IsAccessGranted(ACM_MODIFY);

  AColumn.Editable := LEditable;
  if LEditable then
  begin
    LEditor := AEditorManager.CreateGridCellEditor(FEditorGridPanel, AViewField);
    if Supports(LEditor, IEFSubject, LSubject) then
      LSubject.AttachObserver(Self);
    FEditItems.Add(LEditor);
    AColumn.Editor := LEditor;
  end;
end;

procedure TKExtGridPanel.InitGridColumns;
var
  I: Integer;
  LLayout: TKLayout;
  LLayoutNode: TEFNode;
  LAutoExpandColumn: string;
  LEditorManager: TKExtEditorManager;
  LFieldName: string;

  procedure AddGridColumn(const AViewField: TKViewField;
    const ALayoutNode: TEFNode);
  var
    LColumn: TExtGridColumn;
    LColumnWidth: Integer;

    function SetRenderer(const AColumn: TExtGridColumn): Boolean;
    var
      LImages: TEFNode;
      LTriples: TEFTriples;
      I: Integer;
      LCustomRenderer: TEFNode;
      LColorPairs: TEFPairs;
      LColors: TEFNode;
      LAllowedValues: TEFPairs;
      LJSCode: string;
    begin
      Result := False;

      LCustomRenderer := AViewField.FindNode('JSRenderer');
      if Assigned(LCustomRenderer) and (LCustomRenderer.AsString <> '') then
      begin
        AColumn.RendererExtFunction := AColumn.JSFunction('value, metaData, record, rowIndex, colIndex, store',
          LCustomRenderer.AsExpandedString);
        Result := True;
        Exit;
      end;

      if Assigned(ALayoutNode) then
        LImages := ALayoutNode.FindNode('Images')
      else
        LImages := nil;
      if not Assigned(LImages) then
        LImages := AViewField.FindNode('Images');
      if Assigned(LImages) and (LImages.ChildCount > 0) then
      begin
        // Get image list into array of triples (URL/regexp/template).
        SetLength(LTriples, LImages.ChildCount);
        for I := 0 to LImages.ChildCount - 1 do
        begin
          LTriples[I].Value1 := Session.Config.GetImageURL(LImages.Children[I].Name);
          LTriples[I].Value2 := LImages.Children[I].AsExpandedString;
          LTriples[I].Value3 := LImages.Children[I].GetExpandedString('DisplayTemplate');
          if LTriples[I].Value3 = '' then
            LTriples[I].Value3 := AViewField.DisplayTemplate;
        end;
        // Pass array to the client-side renderer.
        AColumn.RendererExtFunction := AColumn.JSFunction('value',
          Format('return formatWithImage(value, [%s], %s);',
            [TriplesToJSON(LTriples), IfThen(AViewField.BlankValue, 'false', 'true')]));
        Result := True;
        Exit;
      end;

      if Assigned(ALayoutNode) then
        LColors := ALayoutNode.FindNode('Colors')
      else
        LColors := nil;
      if not Assigned(LColors) then
        LColors := AViewField.FindNode('Colors');
      if Assigned(LColors) and (LColors.ChildCount > 0) then
      begin
        LColorPairs := AViewField.GetColorsAsPairs;
        // Get color list into array of triples (color/regexp/template).
        SetLength(LTriples, Length(LColorPairs));
        for I := 0 to High(LColorPairs) do
        begin
          LTriples[I].Value1 := LColorPairs[I].Key;
          LTriples[I].Value2 := TEFMacroExpansionEngine.Instance.Expand(LColorPairs[I].Value);
          LTriples[I].Value3 := AViewField.DisplayTemplate;
        end;
        // Pass array to the client-side renderer.
        AColumn.RendererExtFunction := AColumn.JSFunction('value, metaData',
          Format(
            'metaData.css += getColorStyleRuleForValue(value, [%s]);' +
            'return %s ? null : formatWithDisplayTemplate(value, ''%s'');',
            [PairsToJSON(LColorPairs), IfThen(AViewField.BlankValue, 'true', 'false'), AViewField.DisplayTemplate]));
        Result := True;
        Exit;
      end;

      LAllowedValues := AViewField.GetChildrenAsPairs('AllowedValues', True);
      if Length(LAllowedValues) > 0 then
      begin
        LJSCode := '';
        for I := Low(LAllowedValues) to High(LAllowedValues) do
        begin
          LAllowedValues[I].Value := _(LAllowedValues[I].Value);
          LJSCode := LJSCode + Format('if (v == "%s") return "%s";' + sLineBreak, [LAllowedValues[I].Key, LAllowedValues[I].Value]);
        end;
        LJSCode := LJSCode + 'return v;';
        AColumn.RendererExtFunction := AColumn.JSFunction('v', LJSCode);
        Result := True;
        Exit;
      end;
    end;

    function CreateColumn: TExtGridColumn;
    var
      LDataType: TEFDataType;
      LFormat: string;
      LAlignNode: TEFNode;

      function GetDisplayFormat: string;
      var
        LDisplayFormatNode: TEFNode;
      begin
        if Assigned(ALayoutNode) then
          LDisplayFormatNode := ALayoutNode.FindNode('DisplayFormat')
        else
          LDisplayFormatNode := nil;
        if Assigned(LDisplayFormatNode) then
          Result := LDisplayFormatNode.AsString
        else
          Result := AViewField.DisplayFormat;
      end;

    begin
      LDataType := AViewField.DataType;
      if LDataType is TKReferenceDataType then
        LDataType := AViewField.ModelField.ReferencedModel.CaptionField.DataType;

      if LDataType is TEFBooleanDataType then
      begin
        // Don't use TExtGridBooleanColumn here, otherwise the renderer will be inneffective.
        Result := TExtGridColumn.CreateAndAddTo(FEditorGridPanel.Columns);
        if not SetRenderer(Result) then
          Result.Renderer := 'checkboxRenderer';
      end
      else if LDataType is TEFDateDataType then
      begin
        Result := TExtGridDateColumn.CreateAndAddTo(FEditorGridPanel.Columns);
        LFormat := GetDisplayFormat;
        if LFormat = '' then
          LFormat := Session.Config.UserFormatSettings.ShortDateFormat;
        TExtGridDateColumn(Result).Format := DelphiDateFormatToJSDateFormat(LFormat);
      end
      else if LDataType is TEFTimeDataType then
      begin
        Result := TExtGridColumn.CreateAndAddTo(FEditorGridPanel.Columns);
        if not SetRenderer(Result) then
        begin
          LFormat := GetDisplayFormat;
          if LFormat = '' then
            LFormat := Session.Config.UserFormatSettings.ShortTimeFormat;
          Result.RendererExtFunction := Result.JSFunction('v',
            Format('return formatTime(v, "%s");', [DelphiTimeFormatToJSTimeFormat(LFormat)]));
        end;
      end
      else if LDataType is TEFDateTimeDataType then
      begin
        Result := TExtGridDateColumn.CreateAndAddTo(FEditorGridPanel.Columns);
        LFormat := GetDisplayFormat;
        if LFormat = '' then
          LFormat := Session.Config.UserFormatSettings.ShortDateFormat + ' ' +
            Session.Config.UserFormatSettings.ShortTimeFormat;
        TExtGridDateColumn(Result).Format := DelphiDateTimeFormatToJSDateTimeFormat(LFormat);
      end
      else if LDataType is TEFIntegerDataType then
      begin
        Result := TExtGridNumberColumn.CreateAndAddTo(FEditorGridPanel.Columns);
        if not SetRenderer(Result) then
        begin
          LFormat := GetDisplayFormat;
          if LFormat = '' then
            LFormat := '0,000'; // '0';
          TExtGridNumberColumn(Result).Format := AdaptExtNumberFormat(LFormat, Session.Config.UserFormatSettings);
        end;
      end
      else if (LDataType is TEFFloatDataType) or (LDataType is TEFDecimalDataType) then
      begin
        Result := TExtGridNumberColumn.CreateAndAddTo(FEditorGridPanel.Columns);
        if not SetRenderer(Result) then
        begin
          LFormat := GetDisplayFormat;
          if LFormat = '' then
            LFormat := '0,000.' + DupeString('0', AViewField.DecimalPrecision);
          TExtGridNumberColumn(Result).Format := AdaptExtNumberFormat(LFormat, Session.Config.UserFormatSettings);
        end;
      end
      else if LDataType is TEFCurrencyDataType then
      begin
        Result := TExtGridNumberColumn.CreateAndAddTo(FEditorGridPanel.Columns);
        if not SetRenderer(Result) then
        begin
          { TODO : format as money? }
          LFormat := GetDisplayFormat;
          if LFormat = '' then
            LFormat := '0,000.00';
          TExtGridNumberColumn(Result).Format := AdaptExtNumberFormat(LFormat, Session.Config.UserFormatSettings);
        end;
      end
      else
      begin
        Result := TExtGridColumn.CreateAndAddTo(FEditorGridPanel.Columns);
        SetRenderer(Result);
      end;

      //Column alignment
      Result.Align := OptionAsGridColumnAlign(LDataType.GetDefaultColumnAlignment);
      if Assigned(ALayoutNode) then
      begin
        LAlignNode := ALayoutNode.FindNode('Align');
        if Assigned(LAlignNode) then
          Result.Align := OptionAsGridColumnAlign(LAlignNode.AsString);
      end;

      if not ViewTable.IsFieldVisible(AViewField) and not (AViewField.AliasedName = GetGroupingFieldName) then
        FEditorGridPanel.ColModel.SetHidden(FEditorGridPanel.Columns.Count - 1, True);

      //In-place editing
      SetGridColumnEditor(LEditorManager, AViewField, ALayoutNode, Result);
    end;

  begin
    LColumn := CreateColumn;
    LColumn.Sortable := not AViewField.IsBlob;
    if Assigned(ALayoutNode) then
      LColumn.Header := _(ALayoutNode.GetString('DisplayLabel', AViewField.DisplayLabel))
    else
      LColumn.Header := _(AViewField.DisplayLabel);
    LColumn.DataIndex := AViewField.AliasedName;

    if Assigned(ALayoutNode) then
      LColumnWidth := ALayoutNode.GetInteger('DisplayWidth', AViewField.DisplayWidth)
    else
      LColumnWidth := AViewField.DisplayWidth;

    if LColumnWidth = 0 then
      LColumnWidth := Min(IfThen(AViewField.Size = 0, 40, AViewField.Size), 40);
    LColumn.Width := CharsToPixels(LColumnWidth);
  end;

  function SupportedAsGridColumn(const AViewField: TKViewField): Boolean;
  begin
    Result := not (AViewField.DataType is TEFBlobDataType);
  end;

  procedure AddColumn(const AViewField: TKViewField;
    const ALayoutNode: TEFNode);
  begin
    if SupportedAsGridColumn(AViewField) then
    begin
      if AViewField.IsAccessGranted(ACM_READ) then
        AddGridColumn(AViewField, ALayoutNode);
    end;
  end;

begin
  Assert(ViewTable <> nil);

  LEditorManager := TKExtEditorManager.Create;
  try
    FreeAndNil(FEditItems);
    FEditItems := TKEditItemList.Create;
    // Only in-place editing supported ATM, not inserting.
    LEditorManager.Operation := eoUpdate;
    LEditorManager.OnGetSession :=
      procedure (out ASession: TKExtSession)
      begin
        ASession := Session;
      end;
    LLayout := FindViewLayout('Grid');
    if LLayout <> nil then
    begin
      for I := 0 to LLayout.ChildCount - 1 do
      begin
        LLayoutNode := LLayout.Children[I];
        LFieldName := LLayoutNode.AsString;
        AddColumn(ViewTable.FieldByAliasedName(LFieldName), LLayoutNode);
      end;
    end
    else
    begin
      for I := 0 to ViewTable.FieldCount - 1 do
        AddColumn(ViewTable.Fields[I], nil);
    end;
    LAutoExpandColumn := ViewTable.GetString('Controller/AutoExpandFieldName');
    if LAutoExpandColumn <> '' then
      FEditorGridPanel.AutoExpandColumn := LAutoExpandColumn;
  finally
    FreeAndNil(LEditorManager);
  end;
end;

function TKExtGridPanel.GetRowColorPatterns(out AFieldName: string): TEFPairs;
var
  LFieldNode: TEFNode;
begin
  AFieldName := '';
  Result := nil;
  LFieldNode := ViewTable.FindNode('Controller/RowColorField');
  if Assigned (LFieldNode) then
  begin
    AFieldName := LFieldNode.AsExpandedString;
    if LFieldNode.ChildCount > 0 then
      Result := LFieldNode.GetChildPairs(True)
    else
      Result := ViewTable.FieldByName(LFieldNode.AsExpandedString).GetColorsAsPairs;
  end;
end;

procedure TKExtGridPanel.SelectionChanged;
begin
end;

procedure TKExtGridPanel.InitColumnEditors(const ARecord: TKViewTableRecord);
begin
  Assert(Assigned(ARecord));

  // Set record fields and load data.
  FEditItems.AllEditors(
    procedure (AEditor: IKExtEditor)
    begin
      AEditor.RecordField := ARecord.FieldByName(AEditor.FieldName);
      AEditor.RefreshValue;
    end);
end;

procedure TKExtGridPanel.SetViewTable(const AValue: TKViewTable);
var
  LView: TKDataView;
  LViewTable: TKViewTable;
  LEventName: string;
begin
  LView := View;
  LViewTable := AValue;

  Assert(Assigned(AValue));
  Assert(Assigned(LView));
  Assert(Assigned(FEditorGridPanel));

  FInplaceEditing := LView.GetBoolean('Controller/InplaceEditing');

  inherited;

  if Title = '' then
  begin
    if IsLookupMode then
      Title := _(Format('Choose %s', [LViewTable.DisplayLabel]))
    else
      Title := _(LViewTable.PluralDisplayLabel);
  end;

  if FInplaceEditing then
    FEditorGridPanel.ClicksToEdit := 1;

  CreateGridView;

  if not LViewTable.GetBoolean('Controller/IsMultiSelect', False) then
    FSelectionModel.SingleSelect := True;

  if not FInplaceEditing and HasDefaultAction then
  begin
    if Session.IsMobileBrowser then
      LEventName := IfThen(HasExplicitDefaultAction, 'rowclick', '')
    else
      LEventName := 'rowdblclick';
    if LEventName <> '' then
      FEditorGridPanel.On(LEventName, GetSelectCall(DefaultAction));
  end;

  // By default show paging toolbar for large models.
  if GetIsPaged then
  begin
    FPageRecordCount := LViewTable.GetInteger('Controller/PageRecordCount', 100);
    FEditorGridPanel.Bbar := CreatePagingToolbar;
  end;

  InitGridColumns;

  CheckGroupColumn;

  if IsLookupMode then
  begin
    FConfirmButton := TKExtButton.CreateAndAddTo(Buttons);
    FConfirmButton.SetIconAndScale('accept', Config.GetString('ButtonScale', 'medium'));
    FConfirmButton.Text := Config.GetString('LookupConfirmButton/Caption', _('Select'));
    FConfirmButton.Tooltip := Config.GetString('LookupConfirmButton/Tooltip', _('Select the current record and close the window'));
    FConfirmButton.On('click', GetSelectCall(ConfirmLookup));
    FButtonsRequiringSelection.Add(FConfirmButton);

    FCancelButton := TKExtButton.CreateAndAddTo(Buttons);
    FCancelButton.SetIconAndScale('cancel', Config.GetString('ButtonScale', 'medium'));
    FCancelButton.Text := _('Cancel');
    FCancelButton.Tooltip := _('Close the window without selecting a record');
    FCancelButton.On('click', Ajax(CancelLookup));
  end
  else if FInplaceEditing then
  begin
    FConfirmButton := TKExtButton.CreateAndAddTo(Buttons);
    FConfirmButton.SetIconAndScale('accept', Config.GetString('ButtonScale', 'medium'));
    FConfirmButton.Text := Config.GetString('ConfirmButton/Caption', _('Save'));
    FConfirmButton.Tooltip := Config.GetString('ConfirmButton/Tooltip', _('Save changes and finish editing'));
    FConfirmButton.Hidden := True;
    FConfirmButton.On('click', Ajax(ConfirmInplaceChanges));

    FCancelButton := TKExtButton.CreateAndAddTo(Buttons);
    FCancelButton.SetIconAndScale('cancel', Config.GetString('ButtonScale', 'medium'));
    FCancelButton.Text := _('Cancel');
    FCancelButton.Tooltip := _('Cancel changes');
    FCancelButton.Hidden := True;
    FCancelButton.On('click', Ajax(CancelInplaceChanges));

    FEditorGridPanel.On('beforeedit', JSFunction('e', GetBeforeEditJSCode(BeforeEdit)));
    FEditorGridPanel.On('afteredit', JSFunction('e', GetConfirmJSCode(UpdateField)));
  end;
end;

function TKExtGridPanel.GetDefaultRemoteSort: Boolean;
begin
  Result := GetIsPaged;
end;

procedure TKExtGridPanel.CheckGroupColumn;
var
  I: Integer;
  LGroupingFieldName: string;
  LFound: Boolean;
begin
  LGroupingFieldName := GetGroupingFieldName;

  if LGroupingFieldName <> '' then
  begin
    LFound := False;
    for I := 0 to FEditorGridPanel.Columns.Count - 1 do
    begin
      if SameText(TExtGridColumn(FEditorGridPanel.Columns[I]).DataIndex, LGroupingFieldName) then
      begin
        LFound := True;
        Break;
      end;
    end;
    if not LFound then
      raise Exception.CreateFmt('Grouping field %s not found in grid.', [LGroupingFieldName]);
  end;
end;

procedure TKExtGridPanel.ConfirmInplaceChanges;
begin
  ShowConfirmButtons(False);
  ViewTable.Model.SaveRecords(ServerStore, not ViewTable.IsDetail, nil);
  Session.Flash(_('Changes saved succesfully.'));
  LoadData;
end;

procedure TKExtGridPanel.ConfirmLookup;
begin
  GetParentDataPanel.Config.SetObject('Sys/LookupResultRecord', GetCurrentViewRecord);
  CloseHostContainer;
  GetParentDataPanel.NotifyObservers('LookupConfirmed');
end;

procedure TKExtGridPanel.CancelInplaceChanges;
begin
  ShowConfirmButtons(False);
  ServerStore.Records.MarkAsClean;
  LoadData;
end;

procedure TKExtGridPanel.CancelLookup;
begin
  CloseHostContainer;
  GetParentDataPanel.NotifyObservers('LookupCanceled');
end;

procedure TKExtGridPanel.ShowConfirmButtons(const AShow: Boolean);
begin
  if AShow then
  begin
    FConfirmButton.Show;
    FCancelButton.Show;
  end
  else
  begin
    FConfirmButton.Hide;
    FCancelButton.Hide;
  end;
  DoLayout();
end;

procedure TKExtGridPanel.UpdateField;
var
  LReqBody: ISuperObject;
  LError: string;
begin
  LReqBody := SO(Session.RequestBody);
  LError := UpdateRecord(ServerStore.GetRecord(LReqBody.O['new'], Session.Config.UserFormatSettings), LReqBody.O['new'], False, True);
  if LError = '' then
    // ok - nothing
  else
  begin
    // go back in edit mode.
    //FEditorGridPanel.StartEditing(LReqBody.I['rowIndex'], 0);
  end;
end;

procedure TKExtGridPanel.UpdateObserver(const ASubject: IEFSubject; const AContext: string);
begin
  if MatchText(AContext, ['Confirmed', 'Canceled']) and Supports(ASubject.AsObject, IKExtController) then
  begin
    if not FClientStoreOnLoadSet then
    begin
      ClientStore.On('load', FSelectionModel.SelectFirstRow);
      FClientStoreOnLoadSet := True;
    end;
  end;
  inherited;
end;

procedure TKExtGridPanel.LoadData;
begin
  if Assigned(FPagingToolbar) then
  begin
    // Calling both DoRefresh and MoveFirst causes a double call to GetRecordPage.
    // Since we now query the database every time in GetRecordPage,
    // calling MoveFirst is enough to trigger a refresh AND a move to the first
    // page if not there already.
    //FPagingToolbar.DoRefresh;
    FPagingToolbar.MoveFirst;
  end
  else
    inherited;
end;

procedure TKExtGridPanel.ExecuteNamedAction(const AActionName: string);
begin
  if (AActionName = 'LookupConfirm') then
    FConfirmButton.PerformClick
  else
    inherited;
end;

function TKExtGridPanel.CreatePagingToolbar: TExtPagingToolbar;
begin
  Assert(ViewTable <> nil);

  FPagingToolbar := TExtPagingToolbar.Create(Self);
  FPagingToolbar.Store := FEditorGridPanel.Store;
  FPagingToolbar.DisplayInfo := False;
  FPagingToolbar.PageSize := FPageRecordCount;
  FPagingToolbar.Cls := 'k-bbar';
  Result := FPagingToolbar;
  //FPagingToolbar.Store := nil; // Avoid double destruction of the store.
end;

procedure TKExtGridPanel.Activate;
begin
  inherited;
  if Assigned(FSelectionModel) then
    FSelectionModel.SelectFirstRow;
end;

function TKExtGridPanel.AddActionButton(const AUniqueId: string;
  const AView: TKView; const AToolbar: TKExtToolbar): TKExtActionButton;
begin
  Result := inherited AddActionButton(AUniqueId, AView, AToolbar);

  if AView.GetBoolean('Controller/RequireSelection', True) then
    FButtonsRequiringSelection.Add(Result);
end;

function TKExtGridPanel.GetBeforeEditJSCode(const AMethod: TExtProcedure): string;
var
  LCode: string;
begin
  LCode :=
    'var json = new Object;' + sLineBreak +
    'json.data = e.record.data;' + sLineBreak;
  LCode := LCode + GetPOSTAjaxCode(AMethod, [], 'json') + sLineBreak;
  Result := LCode;
end;

function TKExtGridPanel.GetConfirmJSCode(const AMethod: TExtProcedure): string;
var
  LCode: string;
begin
  LCode :=
    'var json = new Object;' + sLineBreak +
    'json.new = e.record.data;' + sLineBreak;

  LCode := LCode + GetJSFunctionCode(
    procedure
    begin
      FEditItems.AllEditors(
        procedure (AEditor: IKExtEditor)
        begin
          AEditor.StoreValue('json.new');
        end);
    end,
    False) + sLineBreak;

  LCode := LCode + GetPOSTAjaxCode(AMethod, [], 'json') + sLineBreak;
  Result := LCode;
end;

procedure TKExtGridPanel.AddTopToolbarToolViewButtons;
begin
  { TODO : Allow to specify the relative order of Controller-level and ViewTable-level tool buttons? }
  inherited AddToolViewButtons(ViewTable.FindNode('Controller/ToolViews'), TopToolbar);
end;

function TKExtGridPanel.GetSelectConfirmCall(const AMessage: string; const AMethod: TExtProcedure): string;
begin
  if IsMultiSelect then
    Result := Format('confirmCall("%s", "%s", ajaxMultiSelection, {methodURL: "%s", selModel: %s, fieldNames: "%s"});',
      [_(Session.Config.AppTitle), AMessage, MethodURI(AMethod),
      FSelectionModel.JSName, Join(ViewTable.GetKeyFieldAliasedNames, ',')])
  else
    { TODO :
      Add CaptionField to ViewTable for cases when the model's CaptionField
      is not part of the ViewTable or is aliased. }
    Result := Format('selectConfirmCall("%s", "%s", %s, "%s", {methodURL: "%s", selModel: %s, fieldNames: "%s"});',
      [_(Session.Config.AppTitle), AMessage, FSelectionModel.JSName, ViewTable.Model.CaptionField.FieldName,
      MethodURI(AMethod), FSelectionModel.JSName, Join(ViewTable.GetKeyFieldAliasedNames, ',')]);
end;

function TKExtGridPanel.GetSelectCall(const AMethod: TExtProcedure): TExtFunction;
var
  LKeyFieldNames: string;
begin
  LKeyFieldNames := Join(ViewTable.GetKeyFieldAliasedNames, ',');
  Result := AjaxSelection(AMethod, FSelectionModel, LKeyFieldNames, LKeyFieldNames, []);
end;

initialization
  TKExtControllerRegistry.Instance.RegisterClass('GridPanel', TKExtGridPanel);

finalization
  TKExtControllerRegistry.Instance.UnregisterClass('GridPanel');

end.
