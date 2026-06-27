/*
 * AppController.j
 * Integrated FHIR R6 Eligibility Criteria Editor & HPO Tree Browser
 */

@import <Foundation/Foundation.j>
@import <AppKit/AppKit.j>

// Helper to allow native JS object serialization to work nicely in Cappuccino
@implementation CPDictionary (JSONHelper)
- (id)JSObject
{
    var obj = {};
    var keys = [self allKeys];
    for (var i = 0; i < [keys count]; i++)
    {
        var key = keys[i];
        var val = [self objectForKey:key];

        if ([val respondsToSelector:@selector(JSObject)])
            obj[key] = [val JSObject];
        else if ([val isKindOfClass:[CPArray class]])
            obj[key] = [val JSObject];
        else
            obj[key] = val;
    }
    return obj;
}
@end

@implementation CPArray (JSONHelper)
- (id)JSObject
{
    var arr = [];
    for (var i = 0; i < [self count]; i++)
    {
        var val = [self objectAtIndex:i];
        if ([val respondsToSelector:@selector(JSObject)])
            [arr addObject:[val JSObject]];
        else
            [arr addObject:val];
    }
    return arr;
}
@end


// --------------------------------------------------------------------------------
// FHIRRuleEditor Subclass
// --------------------------------------------------------------------------------

@implementation FHIRRuleEditor : CPRuleEditor
{
    BOOL _insertCompoundMode;
}

- (void)setInsertCompoundMode:(BOOL)flag
{
    _insertCompoundMode = flag;
}

- (BOOL)insertCompoundMode
{
    return _insertCompoundMode;
}

- (void)_addOptionFromSlice:(id)slice ofRowType:(unsigned int)type
{
    var forcedType = _insertCompoundMode ? CPRuleEditorRowTypeCompound : CPRuleEditorRowTypeSimple;
    [super _addOptionFromSlice:slice ofRowType:forcedType];
}

@end


// --------------------------------------------------------------------------------
// FHIRRuleDelegate
// --------------------------------------------------------------------------------

@implementation FHIRRuleDelegate : CPObject
{
    id _controller;
}

- (id)initWithController:(id)aController
{
    self = [super init];
    if (self)
    {
        _controller = aController;
    }
    return self;
}

- (int)ruleEditor:(CPRuleEditor)editor numberOfChildrenForCriterion:(id)criterion withRowType:(CPRuleEditorRowType)rowType
{
    if (rowType === CPRuleEditorRowTypeCompound)
    {
        if (criterion == nil) return 2; // "Any" / "All"
        if (criterion == CPOrPredicateType || criterion == CPAndPredicateType) return 1; // logical text
        return 0;
    }

    if (rowType === CPRuleEditorRowTypeSimple)
    {
        if (criterion == nil) return 1; // "Phenotypic Feature"
        if (criterion == @"phenotype") return 2; // "Inclusion" vs "Exclusion"
        if (criterion == @"inclusion" || criterion == @"exclusion") return 1; // text input placeholder
    }
    return 0;
}

- (id)ruleEditor:(CPRuleEditor)editor child:(int)index forCriterion:(id)criterion withRowType:(CPRuleEditorRowType)rowType
{
    if (rowType === CPRuleEditorRowTypeCompound)
    {
        if (criterion == nil)
            return (index == 0) ? CPAndPredicateType : CPOrPredicateType;

        return @"_logical_text_";
    }

    if (criterion == nil)
        return @"phenotype";

    if (criterion == @"phenotype")
        return (index == 0) ? @"inclusion" : @"exclusion";

    if (criterion == @"inclusion" || criterion == @"exclusion")
        return @"_value_field_";

    return nil;
}

- (id)ruleEditor:(CPRuleEditor)editor displayValueForCriterion:(id)criterion inRow:(int)row
{
    if (criterion === CPAndPredicateType) return @"All";
    if (criterion === CPOrPredicateType) return @"Any";
    if (criterion === @"_logical_text_") return @"of the following are true";

    if (criterion == @"phenotype") return @"Symptom / Phenotype";
    if (criterion == @"inclusion") return @"Must be present (Inclusion)";
    if (criterion == @"exclusion") return @"Must NOT be present (Exclusion)";

    if (criterion == @"_value_field_")
    {
        if ([_controller respondsToSelector:@selector(importedTextFieldForRow:)])
        {
            var cachedField = [_controller importedTextFieldForRow:row];
            if (cachedField)
            {
                return cachedField;
            }
        }

        var inputField = [[CPTextField alloc] initWithFrame:CGRectMake(0, 0, 160, 24)];
        [inputField setEditable:YES];
        [inputField setBezeled:YES];
        [inputField setBackgroundColor:[CPColor whiteColor]];
        [inputField setPlaceholderString:@"e.g., Corneal erosion"];
        [inputField setTarget:_controller];
        [inputField setAction:@selector(ruleEditorDidChange:)];

        [[CPNotificationCenter defaultCenter] addObserver:_controller
                                                 selector:@selector(ruleEditorDidChange:)
                                                     name:CPControlTextDidChangeNotification
                                                   object:inputField];

        return inputField;
    }

    return criterion;
}

- (CPDictionary)ruleEditor:(CPRuleEditor)editor predicatePartsForCriterion:(id)criterion withDisplayValue:(id)value inRow:(int)row
{
    var result = [CPMutableDictionary dictionary];

    if (criterion === CPOrPredicateType || criterion === CPAndPredicateType)
    {
        [result setObject:criterion forKey:CPRuleEditorPredicateCompoundType];
    }
    else if (criterion === @"phenotype")
    {
        [result setObject:[CPExpression expressionForKeyPath:@"phenotype"] forKey:CPRuleEditorPredicateLeftExpression];
    }
    else if (criterion === @"inclusion")
    {
        [result setObject:[CPNumber numberWithInt:CPEqualToPredicateOperatorType] forKey:CPRuleEditorPredicateOperatorType];
        [result setObject:[CPNumber numberWithInt:CPDirectPredicateModifier] forKey:CPRuleEditorPredicateComparisonModifier];
        [result setObject:[CPNumber numberWithInt:CPCaseInsensitivePredicateOption] forKey:CPRuleEditorPredicateOptions];
    }
    else if (criterion === @"exclusion")
    {
        [result setObject:[CPNumber numberWithInt:CPNotEqualToPredicateOperatorType] forKey:CPRuleEditorPredicateOperatorType];
        [result setObject:[CPNumber numberWithInt:CPDirectPredicateModifier] forKey:CPRuleEditorPredicateComparisonModifier];
        [result setObject:[CPNumber numberWithInt:CPCaseInsensitivePredicateOption] forKey:CPRuleEditorPredicateOptions];
    }
    else if (criterion === @"_value_field_")
    {
        var textValue = [value respondsToSelector:@selector(stringValue)] ? [value stringValue] : @"";
        [result setObject:[CPExpression expressionForConstantValue:textValue] forKey:CPRuleEditorPredicateRightExpression];
    }
    return result;
}

@end


// --------------------------------------------------------------------------------
// AppController
// --------------------------------------------------------------------------------

@implementation AppController : CPObject
{
    CPTabView            _tabView;

    // TAB 1: FHIR Criteria Editor
    FHIRRuleEditor       _ruleEditor;
    FHIRRuleDelegate     _ruleDelegate;
    CPTextView           _synopsisInputTextView;
    CPPopUpButton        _modelPopUpButton;
    CPButton             _extractButton;
    CPButton             _addRuleBtn;
    CPButton             _addGroupBtn;
    CPButton             _clearBtn;
    CPButton             _showJsonBtn;

    CPTextView           _jsonTextView; // Off-screen syncing textview for helper operations
    CPPopover            _jsonPopover;
    CPTextView           _popoverTextView;

    CPArray              _currentTextFields;
    int                  _currentTextFieldIndex;
    BOOL                 _isImportingJSON;
    CPMutableDictionary  _importedTextFieldsByRow;

    // TAB 2: HPO Tree Browser (OntoMan2 Integration)
    CPTreeController     treeController;
    CPOutlineView        outlineView;
    CPTextView           definitionTextView;
    CPTableView          synonymsTableView;
    CPTableView          xrefsTableView;
    CPTableView          downstreamTableView;
    CPCheckBox           _nameOnlyCheckbox;
    CPTextField          _searchStatusLabel;
    CPTextField          _searchField;
    CPPopover            _exportPopover;
    CPTextView           _exportTextView;

    CPArray              _allRoots;
    CPArray              _synonyms;
    CPArray              _xrefs;
    CPArray              _downstreamTerms;
    CPArray              _matchedIndexPaths;
    int                  _currentMatchIndex;
}

- (void)applicationDidFinishLaunching:(CPNotification)aNotification
{
    var theWindow = [[CPWindow alloc] initWithContentRect:CGRectMake(0, 0, 1000, 750) styleMask:CPBorderlessBridgeWindowMask];
    [theWindow setTitle:@"Clinical Trial Eligibility & HPO Suite"];
    [theWindow center];

    var contentView = [theWindow contentView];
    var bounds = [contentView bounds];

    // --- MAIN TAB VIEW ---
    _tabView = [[CPTabView alloc] initWithFrame:bounds];
    [_tabView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [contentView addSubview:_tabView];

    _isImportingJSON = NO;
    _importedTextFieldsByRow = nil;

    _jsonTextView = [[CPTextView alloc] initWithFrame:CGRectMakeZero()];
    [_jsonTextView setDelegate:self];

    [self _buildFHIRTab];
    [self _buildHPOTab];

    [theWindow orderFront:self];
    [self fetchRoots];
}

// --------------------------------------------------------------------------------
// Tab Layout Builders
// --------------------------------------------------------------------------------

- (void)_buildFHIRTab
{
    var tab1 = [[CPTabViewItem alloc] initWithIdentifier:@"fhirTab"];
    [tab1 setLabel:@"FHIR Criteria Editor"];

    var tab1View = [[CPView alloc] initWithFrame:[_tabView bounds]];
    [tab1 setView:tab1View];
    [_tabView addTabViewItem:tab1];

    var splitView = [[CPSplitView alloc] initWithFrame:[tab1View bounds]];
    [splitView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [splitView setVertical:YES];

    var leftWidth = CGRectGetWidth([tab1View bounds]) * 0.35;
    var rightWidth = CGRectGetWidth([tab1View bounds]) - leftWidth - [splitView dividerThickness];

    // --- Left Control Panel (Synopsis Input & Extraction) ---
    var leftContainer = [[CPView alloc] initWithFrame:CGRectMake(0, 0, leftWidth, CGRectGetHeight([tab1View bounds]))];
    [leftContainer setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];

    var synopsisBox = [[CPBox alloc] initWithFrame:CGRectMake(10, 10, leftWidth - 20, CGRectGetHeight([tab1View bounds]) - 160)];
    [synopsisBox setTitle:@"Clinical Study Synopsis / Protocol Text"];
    [synopsisBox setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];

    var synScroll = [[CPScrollView alloc] initWithFrame:[[synopsisBox contentView] bounds]];
    [synScroll setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [synScroll setAutohidesScrollers:YES];

    _synopsisInputTextView = [[CPTextView alloc] initWithFrame:[synScroll bounds]];
    [_synopsisInputTextView setAutoresizingMask:CPViewWidthSizable];
    [_synopsisInputTextView setFont:[CPFont fontWithName:@"Helvetica" size:12.0]];
    
    // Dry Eye syndrome clinical trial protocol synopsis
    var demoSynopsis = "Clinical Study Protocol Synopsis: Dry Eye Syndrome Efficacy Trial (Phase II)\n\n" +
                       "Objective:\n" +
                       "To evaluate the efficacy and safety of Ophthalmic Solution DBB-026 in patients with moderate to severe Keratoconjunctivitis Sicca (Dry Eye Disease).\n\n" +
                       "Patient Eligibility Criteria:\n\n" +
                       "Inclusion Criteria:\n" +
                       "- Patient must have a documented clinical diagnosis of Keratoconjunctivitis Sicca (Dry Eye Disease).\n" +
                       "- Patient must present with clear evidence of corneal epithelial erosion or punctate keratitis.\n" +
                       "- Subjective symptoms must include severe ocular discomfort, foreign body sensation, or persistent ocular burning.\n" +
                       "- Decreased tear production must be confirmed with a Schirmer's I test result of 10 mm/5 minutes or less.\n\n" +
                       "Exclusion Criteria:\n" +
                       "- Must NOT have any active ocular infection (such as bacterial conjunctivitis, keratitis, or blepharitis).\n" +
                       "- No history of refractive corneal surgery (e.g., LASIK, PRK) within the past 180 days.\n" +
                       "- Patients with secondary Sjögren's syndrome or active ocular allergy are excluded.";
    
    [_synopsisInputTextView setString:demoSynopsis];
    
    [synScroll setDocumentView:_synopsisInputTextView];
    [[synopsisBox contentView] addSubview:synScroll];
    [leftContainer addSubview:synopsisBox];

    var settingsBox = [[CPBox alloc] initWithFrame:CGRectMake(10, CGRectGetHeight([tab1View bounds]) - 145, leftWidth - 20, 105)];
    [settingsBox setTitle:@"Cognitive Processing Extraction"];
    [settingsBox setAutoresizingMask:CPViewWidthSizable | CPViewMinYMargin];

    var modelLabel = [CPTextField labelWithTitle:@"LLM Model:"];
    [modelLabel setFrame:CGRectMake(10, 15, 80, 20)];
    [[settingsBox contentView] addSubview:modelLabel];

    _modelPopUpButton = [[CPPopUpButton alloc] initWithFrame:CGRectMake(90, 12, CGRectGetWidth([settingsBox bounds]) - 105, 24) pullsDown:NO];
    [_modelPopUpButton setAutoresizingMask:CPViewWidthSizable];
    [_modelPopUpButton addItemWithTitle:@"gpt-oss-120b"];
    [_modelPopUpButton addItemWithTitle:@"gemma4:26b-mlx"];
    [[settingsBox contentView] addSubview:_modelPopUpButton];

    _extractButton = [[CPButton alloc] initWithFrame:CGRectMake(10, 48, CGRectGetWidth([settingsBox bounds]) - 20, 28)];
    [_extractButton setTitle:@"Extract FHIR Criteria"];
    [_extractButton setTarget:self];
    [_extractButton setAction:@selector(extractFHIRCriteriaAction:)];
    [_extractButton setAutoresizingMask:CPViewWidthSizable];
    [[settingsBox contentView] addSubview:_extractButton];
    [leftContainer addSubview:settingsBox];

    // --- Right Structural Rule Panel ---
    var rightContainer = [[CPView alloc] initWithFrame:CGRectMake(0, 0, rightWidth, CGRectGetHeight([tab1View bounds]))];
    [rightContainer setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];

    var ruleBox = [[CPBox alloc] initWithFrame:CGRectMake(10, 10, rightWidth - 20, CGRectGetHeight([tab1View bounds]) - 65)];
    [ruleBox setTitle:@"Logical Eligibility Framework"];
    [ruleBox setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];

    var ruleScrollView = [[CPScrollView alloc] initWithFrame:[[ruleBox contentView] bounds]];
    [ruleScrollView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [ruleScrollView setAutohidesScrollers:YES];
    [ruleScrollView setBorderType:CPBezelBorder];

    _ruleEditor = [[FHIRRuleEditor alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth([ruleScrollView bounds]), CGRectGetHeight([ruleScrollView bounds]))];
    [_ruleEditor setRowHeight:28.0];
    [_ruleEditor setCanRemoveAllRows:YES];
    [_ruleEditor setNestingMode:CPRuleEditorNestingModeCompound];
    [_ruleEditor setAutoresizingMask:CPViewWidthSizable];

    _ruleDelegate = [[FHIRRuleDelegate alloc] initWithController:self];
    [_ruleEditor setDelegate:_ruleDelegate];
    [_ruleEditor setTarget:self];
    [_ruleEditor setAction:@selector(ruleEditorDidChange:)];

    [ruleScrollView setDocumentView:_ruleEditor];
    [[ruleBox contentView] addSubview:ruleScrollView];
    [rightContainer addSubview:ruleBox];

    var btnY = CGRectGetHeight([tab1View bounds]) - 45;
    _addRuleBtn = [[CPButton alloc] initWithFrame:CGRectMake(15, btnY, 110, 24)];
    [_addRuleBtn setTitle:@"Add Criterion"];
    [_addRuleBtn setTarget:self];
    [_addRuleBtn setAction:@selector(addSimpleRule:)];
    [_addRuleBtn setAutoresizingMask:CPViewMinYMargin];
    [rightContainer addSubview:_addRuleBtn];

    _addGroupBtn = [[CPButton alloc] initWithFrame:CGRectMake(135, btnY, 110, 24)];
    [_addGroupBtn setTitle:@"Add Group"];
    [_addGroupBtn setTarget:self];
    [_addGroupBtn setAction:@selector(addGroupRule:)];
    [_addGroupBtn setAutoresizingMask:CPViewMinYMargin];
    [rightContainer addSubview:_addGroupBtn];

    _clearBtn = [[CPButton alloc] initWithFrame:CGRectMake(255, btnY, 80, 24)];
    [_clearBtn setTitle:@"Reset"];
    [_clearBtn setTarget:self];
    [_clearBtn setAction:@selector(resetEditor:)];
    [_clearBtn setAutoresizingMask:CPViewMinYMargin];
    [rightContainer addSubview:_clearBtn];

    _showJsonBtn = [[CPButton alloc] initWithFrame:CGRectMake(rightWidth - 195, btnY, 180, 24)];
    [_showJsonBtn setTitle:@"View FHIR R6 JSON"];
    [_showJsonBtn setTarget:self];
    [_showJsonBtn setAction:@selector(showJSONPopover:)];
    [_showJsonBtn setAutoresizingMask:CPViewMinYMargin | CPViewMinXMargin];
    [rightContainer addSubview:_showJsonBtn];

    [splitView addSubview:leftContainer];
    [splitView addSubview:rightContainer];
    [tab1View addSubview:splitView];

    [self resetEditor:self];

    [[CPNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ruleEditorDidChange:)
                                                 name:CPRuleEditorRowsDidChangeNotification
                                               object:_ruleEditor];
}

- (void)_buildHPOTab
{
    var tab2 = [[CPTabViewItem alloc] initWithIdentifier:@"hpoTab"];
    [tab2 setLabel:@"HPO Hierarchy Browser"];

    var tab2View = [[CPView alloc] initWithFrame:[_tabView bounds]];
    [tab2 setView:tab2View];
    [_tabView addTabViewItem:tab2];

    var bounds = [tab2View bounds];

    treeController = [[CPTreeController alloc] init];
    [treeController setChildrenKeyPath:@"children"];
    [treeController setLeafKeyPath:@"isLeaf"];

    _synonyms = [];
    _xrefs = [];
    _downstreamTerms = [];
    _matchedIndexPaths = [];
    _currentMatchIndex = -1;

    var topWidth = CGRectGetWidth(bounds) - 40;
    var searchFieldWidth = topWidth - 270;

    _searchField = [[CPSearchField alloc] initWithFrame:CGRectMake(20, 10, searchFieldWidth, 30)];
    [_searchField setAutoresizingMask:CPViewWidthSizable | CPViewMaxYMargin];
    [_searchField setPlaceholderString:@"Search terms, synonyms, descriptions..."];
    [_searchField setTarget:self];
    [_searchField setAction:@selector(searchAction:)];
    [tab2View addSubview:_searchField];

    _searchStatusLabel = [[CPTextField alloc] initWithFrame:CGRectMake(20 + searchFieldWidth + 10, 15, 60, 20)];
    [_searchStatusLabel setStringValue:@""];
    [_searchStatusLabel setAutoresizingMask:CPViewMinXMargin | CPViewMaxYMargin];
    [_searchStatusLabel setAlignment:CPRightTextAlignment];
    [tab2View addSubview:_searchStatusLabel];

    var prevBtn = [[CPButton alloc] initWithFrame:CGRectMake(20 + searchFieldWidth + 80, 13, 30, 24)];
    [prevBtn setTitle:@"<"];
    [prevBtn setAutoresizingMask:CPViewMinXMargin | CPViewMaxYMargin];
    [prevBtn setTarget:self];
    [prevBtn setAction:@selector(prevMatch:)];
    [tab2View addSubview:prevBtn];

    var nextBtn = [[CPButton alloc] initWithFrame:CGRectMake(20 + searchFieldWidth + 115, 13, 30, 24)];
    [nextBtn setTitle:@">"];
    [nextBtn setAutoresizingMask:CPViewMinXMargin | CPViewMaxYMargin];
    [nextBtn setTarget:self];
    [nextBtn setAction:@selector(nextMatch:)];
    [tab2View addSubview:nextBtn];

    _nameOnlyCheckbox = [[CPCheckBox alloc] initWithFrame:CGRectMake(20 + searchFieldWidth + 155, 15, 100, 20)];
    [_nameOnlyCheckbox setTitle:@"Name only"];
    [_nameOnlyCheckbox setAutoresizingMask:CPViewMinXMargin | CPViewMaxYMargin];
    [_nameOnlyCheckbox setState:CPOffState];
    [tab2View addSubview:_nameOnlyCheckbox];

    var splitViewHeight = CGRectGetHeight(bounds) - 90;
    var splitView = [[CPSplitView alloc] initWithFrame:CGRectMake(20, 50, CGRectGetWidth(bounds) - 40, splitViewHeight)];
    [splitView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [splitView setVertical:YES];

    var splitBounds = [splitView bounds];
    var splitWidth = CGRectGetWidth(splitBounds);
    var splitHeight = CGRectGetHeight(splitBounds);
    var dividerWidth = [splitView dividerThickness];

    var leftWidth = (splitWidth - dividerWidth) * 0.60;
    var rightWidth = (splitWidth - dividerWidth) - leftWidth;

    var leftScroll = [[CPScrollView alloc] initWithFrame:CGRectMake(0, 0, leftWidth, splitHeight)];
    [leftScroll setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [leftScroll setAutohidesScrollers:NO];

    outlineView = [[CPOutlineView alloc] initWithFrame:[leftScroll bounds]];
    var column = [[CPTableColumn alloc] initWithIdentifier:@"name"];
    [[column headerView] setStringValue:@"HPO Tree Nodes"];

    [column setResizingMask:CPTableColumnAutoresizingMask];
    [outlineView setColumnAutoresizingStyle:CPTableViewLastColumnOnlyAutoresizingStyle];
    [outlineView addTableColumn:column];
    [outlineView setOutlineTableColumn:column];
    [outlineView setAllowsMultipleSelection:NO];
    [outlineView setDelegate:self];
    [leftScroll setDocumentView:outlineView];
    [splitView addSubview:leftScroll];

    var rightSplitView = [[CPSplitView alloc] initWithFrame:CGRectMake(0, 0, rightWidth, splitHeight)];
    [rightSplitView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [rightSplitView setVertical:NO];

    var defScroll = [[CPScrollView alloc] initWithFrame:CGRectMake(0, 0, rightWidth, splitHeight * 0.25)];
    [defScroll setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [defScroll setAutohidesScrollers:YES];
    [defScroll setHasHorizontalScroller:NO];

    definitionTextView = [[CPTextView alloc] initWithFrame:[defScroll bounds]];
    [definitionTextView setAutoresizingMask:CPViewWidthSizable];
    [definitionTextView setEditable:NO];
    [definitionTextView setSelectable:YES];

    [defScroll setDocumentView:definitionTextView];

    var defBox = [[CPBox alloc] initWithFrame:CGRectMake(0,0, rightWidth, splitHeight * 0.25)];
    [defBox setTitle:@"Term Definition"];
    [defBox setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [[defBox contentView] addSubview:defScroll];
    [rightSplitView addSubview:defBox];

    var xrefScroll = [[CPScrollView alloc] initWithFrame:CGRectMake(0, 0, rightWidth, splitHeight * 0.20)];
    [xrefScroll setAutohidesScrollers:YES];

    xrefsTableView = [[CPTableView alloc] initWithFrame:[xrefScroll bounds]];
    var xrefCol = [[CPTableColumn alloc] initWithIdentifier:@"xref"];
    [xrefCol setSortDescriptorPrototype:[CPSortDescriptor sortDescriptorWithKey:@"xref" ascending:YES]];
    [[xrefCol headerView] setStringValue:@"Database Mapping references"];
    [xrefCol setWidth:rightWidth - 5];
    [xrefsTableView addTableColumn:xrefCol];
    [xrefsTableView setDataSource:self];
    [xrefScroll setDocumentView:xrefsTableView];
    [xrefScroll setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];

    var xrefBox = [[CPBox alloc] initWithFrame:CGRectMake(0,0, rightWidth, splitHeight * 0.20)];
    [xrefBox setTitle:@"Cross References (Xrefs)"];
    [xrefBox setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [[xrefBox contentView] addSubview:xrefScroll];
    [rightSplitView addSubview:xrefBox];

    var synScroll = [[CPScrollView alloc] initWithFrame:CGRectMake(0, 0, rightWidth, splitHeight * 0.25)];
    [synScroll setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [synScroll setAutohidesScrollers:YES];

    synonymsTableView = [[CPTableView alloc] initWithFrame:[synScroll bounds]];
    var synCol = [[CPTableColumn alloc] initWithIdentifier:@"label"];
    [[synCol headerView] setStringValue:@"Associated Synonyms"];
    [synCol setSortDescriptorPrototype:[CPSortDescriptor sortDescriptorWithKey:@"label" ascending:YES]];
    [synCol setWidth:rightWidth - 5];
    [synonymsTableView addTableColumn:synCol];
    [synonymsTableView setDataSource:self];
    [synScroll setDocumentView:synonymsTableView];
    [rightSplitView addSubview:synScroll];

    var textBox = [[CPBox alloc] initWithFrame:CGRectMake(0,0, rightWidth, splitHeight * 0.30)];
    [textBox setTitle:@"Downstream Child Classes"];
    [textBox setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];

    var contentBounds = [[textBox contentView] bounds];

    var downScroll = [[CPScrollView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(contentBounds), CGRectGetHeight(contentBounds) - 34)];
    [downScroll setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [downScroll setAutohidesScrollers:YES];

    downstreamTableView = [[CPTableView alloc] initWithFrame:[downScroll bounds]];
    [downstreamTableView setTarget:self];
    [downstreamTableView setDoubleAction:@selector(doubleClickDownstream:)];

    var downIdCol = [[CPTableColumn alloc] initWithIdentifier:@"id"];
    [[downIdCol headerView] setStringValue:@"Class ID"];
    [downIdCol setSortDescriptorPrototype:[CPSortDescriptor sortDescriptorWithKey:@"id" ascending:YES]];
    [downIdCol setWidth:90];
    [downstreamTableView addTableColumn:downIdCol];

    var downLabelCol = [[CPTableColumn alloc] initWithIdentifier:@"label"];
    [[downLabelCol headerView] setStringValue:@"Ontology Standard Label"];
    [downLabelCol setSortDescriptorPrototype:[CPSortDescriptor sortDescriptorWithKey:@"label" ascending:YES]];
    [downLabelCol setWidth:rightWidth - 98];
    [downstreamTableView addTableColumn:downLabelCol];
    [downstreamTableView setDataSource:self];
    [downScroll setDocumentView:downstreamTableView];
    [[textBox contentView] addSubview:downScroll];

    var exportBtn = [[CPButton alloc] initWithFrame:CGRectMake(3, CGRectGetMaxY([downScroll bounds]) + 3, 120, 24)];
    [exportBtn setAutoresizingMask:CPViewMinYMargin | CPViewMaxXMargin];
    [exportBtn setTitle:@"Export Tree IDs"];
    [exportBtn setTarget:self];
    [exportBtn setAction:@selector(exportDownstream:)];
    [[textBox contentView] addSubview:exportBtn];
    [rightSplitView addSubview:textBox];

    [splitView addSubview:rightSplitView];
    [tab2View addSubview:splitView];

    [outlineView bind:@"content" toObject:treeController withKeyPath:@"arrangedObjects" options:nil];
    [outlineView bind:@"selectionIndexPaths" toObject:treeController withKeyPath:@"selectionIndexPaths" options:nil];
}

// --------------------------------------------------------------------------------
// Tab 1: FHIR Criterion Methods & Live Popover Integration
// --------------------------------------------------------------------------------

- (void)addSimpleRule:(id)sender
{
    var selectedRows = [_ruleEditor selectedRowIndexes];
    var targetIndex = [selectedRows count] > 0 ? [selectedRows lastIndex] + 1 : [_ruleEditor numberOfRows];

    [_ruleEditor insertRowAtIndex:targetIndex
                         withType:CPRuleEditorRowTypeSimple
                    asSubrowOfRow:-1
                          animate:YES];
}

- (void)addGroupRule:(id)sender
{
    var selectedRows = [_ruleEditor selectedRowIndexes];
    var targetIndex = [selectedRows count] > 0 ? [selectedRows lastIndex] + 1 : [_ruleEditor numberOfRows];

    [_ruleEditor insertRowAtIndex:targetIndex
                         withType:CPRuleEditorRowTypeCompound
                    asSubrowOfRow:-1
                          animate:YES];
}

- (void)resetEditor:(id)sender
{
    var count = [_ruleEditor numberOfRows];
    if (count > 0)
    {
        // Safe clear: loop in reverse order with includeSubrows:NO 
        // to bypass the forward-scanning framework index bug
        for (var i = count - 1; i >= 0; i--)
        {
            var indexes = [CPIndexSet indexSetWithIndex:i];
            [_ruleEditor removeRowsAtIndexes:indexes includeSubrows:NO];
        }
    }

    [_ruleEditor addRow:self];
    [self updateFHIRGroupRepresentation];
}

- (void)ruleEditorDidChange:(id)sender
{
    if (_isImportingJSON)
        return;

    [self updateFHIRGroupRepresentation];
}

- (id)importedTextFieldForRow:(int)row
{
    if (_importedTextFieldsByRow)
    {
        return [_importedTextFieldsByRow objectForKey:[CPNumber numberWithInt:row]];
    }
    return nil;
}

- (CPArray)_allEditableTextFields
{
    var textFields = [CPMutableArray array];
    [self _collectEditableTextFieldsFromView:_ruleEditor intoArray:textFields];

    [textFields sortUsingFunction:function(tf1, tf2, context) {
        var origin1 = [tf1 convertPoint:CGPointMakeZero() toView:nil];
        var origin2 = [tf2 convertPoint:CGPointMakeZero() toView:nil];

        if (origin1.y < origin2.y) return -1;
        if (origin1.y > origin2.y) return 1;
        if (origin1.x < origin2.x) return -1;
        if (origin1.x > origin2.x) return 1;
        return 0;
    } context:nil];

    return textFields;
}

- (void)_collectEditableTextFieldsFromView:(CPView)aView intoArray:(CPMutableArray)array
{
    if ([aView isKindOfClass:[CPTextField class]] && [aView isEditable])
    {
        [array addObject:aView];
        return;
    }

    var subviews = [aView subviews];
    for (var i = 0; i < [subviews count]; i++)
    {
        [self _collectEditableTextFieldsFromView:subviews[i] intoArray:array];
    }
}

// --------------------------------------------------------------------------------
// FHIR Extraction & Representation Methods
// --------------------------------------------------------------------------------

- (void)extractFHIRCriteriaAction:(id)sender
{
    var synopsisText = [_synopsisInputTextView string];
    if (!synopsisText || [synopsisText length] === 0) {
        alert("Please paste a clinical trial synopsis into the input area first.");
        return;
    }

    [_extractButton setEnabled:NO];
    [_extractButton setTitle:@"Extracting..."];

    var selectedModel = [_modelPopUpButton titleOfSelectedItem];

    var request = [CPURLRequest requestWithURL:"/DBB/extract_fhir_inex_criteria"
                                   cachePolicy:CPURLRequestUseProtocolCachePolicy
                               timeoutInterval:300.0];

    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    var payload = {
        "report": synopsisText,
        "model": selectedModel
    };
    var postData = [CPString stringWithString:JSON.stringify(payload)];
    [request setHTTPBody:postData];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
    {
        [_extractButton setEnabled:YES];
        [_extractButton setTitle:@"Extract FHIR Criteria"];

        if (!error && data) {
            try {
                var parsedData = JSON.parse(data);
                console.log("DEBUG [Backend Response] raw phenopacket: ", parsedData);
                
                // Route directly to the visual importer if the response is already a FHIR Group
                if (parsedData && parsedData.resourceType === "Group") {
                    [self importFHIRGroup:parsedData];
                } else {
                    [self importPhenopacketToEditor:parsedData];
                }
            } catch (e) {
                alert("Error parsing server-side extraction response: " + e.message);
            }
        } else {
            var errorMsg = (error) ? [error localizedDescription] : @"Could not connect to database services.";
            alert("Model Extraction Failure:\n" + errorMsg);
        }
    }];
}

- (void)importPhenopacketToEditor:(id)phenopacket
{
    if (!phenopacket) return;
    var features = phenopacket.phenotypicFeatures || [];
    var characteristics = [];

    for (var i = 0; i < features.length; i++) {
        var feat = features[i];
        if (!feat.type) continue;

        characteristics.push({
            "exclude": feat.exclude ? true : false,
            "valueCodeableConcept": {
                "coding": [{
                    "system": "http://human-phenotype-ontology.org",
                    "code": feat.type.id || "",
                    "display": feat.type.label || ""
                }]
            }
        });
    }

    var rootGroup = {
        "resourceType": "Group",
        "combinationMethod": "all-of",
        "characteristic": characteristics
    };

    [self importFHIRGroup:rootGroup];
}

- (void)showJSONPopover:(id)sender
{
    [self updateFHIRGroupRepresentation];

    if (!_jsonPopover)
    {
        _jsonPopover = [CPPopover new];
        [_jsonPopover setBehavior:CPPopoverBehaviorTransient];
        [_jsonPopover setAppearance:CPPopoverAppearanceMinimal];
        [_jsonPopover setAnimates:YES];

        var containerView = [[CPView alloc] initWithFrame:CGRectMake(0, 0, 500, 420)];

        var scrollView = [[CPScrollView alloc] initWithFrame:[containerView bounds]];
        [scrollView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
        [scrollView setAutohidesScrollers:YES];

        _popoverTextView = [[CPTextView alloc] initWithFrame:[scrollView bounds]];
        [_popoverTextView setAutoresizingMask:CPViewWidthSizable];
        [_popoverTextView setEditable:NO];
        [_popoverTextView setSelectable:YES];
        [_popoverTextView setFont:[CPFont fontWithName:@"Courier" size:11.0]];
        [_popoverTextView setTextColor:[CPColor colorWithRed:0.1 green:0.4 blue:0.1 alpha:1.0]];

        [scrollView setDocumentView:_popoverTextView];
        [containerView addSubview:scrollView];

        var popoverController = [CPViewController new];
        [popoverController setView:containerView];
        [_jsonPopover setContentViewController:popoverController];
    }

    [_popoverTextView setString:[_jsonTextView string]];
    [_jsonPopover showRelativeToRect:[sender bounds] ofView:sender preferredEdge:CPMinYEdge];
}

- (void)updateFHIRGroupRepresentation
{
    if (_isImportingJSON)
        return;

    _isImportingJSON = YES;

    try
    {
        _currentTextFields = [self _allEditableTextFields];
        _currentTextFieldIndex = 0;

        var containedArray = [CPMutableArray array];
        var subgroupCounter = { value: 0 };

        var rootGroup;
        var hasRootCompound = ([_ruleEditor numberOfRows] > 0 && [_ruleEditor rowTypeForRow:0] == CPRuleEditorRowTypeCompound);

        if (hasRootCompound)
        {
            rootGroup = [self _compileGroupForRowIndex:0 containedArray:containedArray subgroupCounter:subgroupCounter];
        }
        else
        {
            rootGroup = [self _compileGroupForRowIndex:-1 containedArray:containedArray subgroupCounter:subgroupCounter];
        }

        [rootGroup setObject:@"Group" forKey:@"resourceType"];
        [rootGroup setObject:@"eligibility-criteria" forKey:@"id"];
        [rootGroup setObject:@"active" forKey:@"status"];
        [rootGroup setObject:@"definitional" forKey:@"membership"];
        [rootGroup setObject:@"person" forKey:@"type"];

        var rootCombMethod = "all-of";
        if (hasRootCompound)
        {
            var criteria = [_ruleEditor criteriaForRow:0];
            if ([criteria count] > 0)
            {
                var methodVal = [criteria objectAtIndex:0];
                if (methodVal === CPOrPredicateType)
                    rootCombMethod = "any-of";
            }
        }
        [rootGroup setObject:rootCombMethod forKey:@"combinationMethod"];

        if ([containedArray count] > 0)
        {
            [rootGroup setObject:containedArray forKey:@"contained"];
        }

        var jsFormattedObject = [rootGroup JSObject];
        var prettyJson = JSON.stringify(jsFormattedObject, null, 2);

        [_jsonTextView setDelegate:nil];
        [_jsonTextView setString:prettyJson];
        [_jsonTextView setDelegate:self];
    }
    catch (e)
    {
        console.error("[FHIR Error] Critical formatting error in compiler: ", e);
    }
    finally
    {
        _isImportingJSON = NO;
    }
}

- (CPMutableDictionary)_compileGroupForRowIndex:(CPInteger)rowIndex containedArray:(CPMutableArray)containedArray subgroupCounter:(id)subgroupCounter
{
    var group = [CPMutableDictionary dictionary];
    [group setObject:@"Group" forKey:@"resourceType"];

    var subrowIndexes = [_ruleEditor subrowIndexesForRow:rowIndex];
    var characteristics = [CPMutableArray array];

    var current_index = [subrowIndexes firstIndex];
    while (current_index !== CPNotFound)
    {
        var rowType = [_ruleEditor rowTypeForRow:current_index];

        if (rowType == CPRuleEditorRowTypeCompound)
        {
            subgroupCounter.value = subgroupCounter.value + 1;
            var subgroupID = "subgroup-" + subgroupCounter.value;

            var subGroup = [self _compileGroupForRowIndex:current_index containedArray:containedArray subgroupCounter:subgroupCounter];
            [subGroup setObject:subgroupID forKey:@"id"];
            [subGroup setObject:@"conceptual" forKey:@"membership"];
            [subGroup setObject:@"person" forKey:@"type"];

            var criteria = [_ruleEditor criteriaForRow:current_index];
            var combMethod = "all-of";
            if ([criteria count] > 0)
            {
                var methodVal = [criteria objectAtIndex:0];
                if (methodVal === CPOrPredicateType)
                    combMethod = "any-of";
            }
            [subGroup setObject:combMethod forKey:@"combinationMethod"];

            [containedArray addObject:subGroup];

            var refCharacteristic = [CPMutableDictionary dictionary];
            [refCharacteristic setObject:@{ @"text": @"Logical subgroup" } forKey:@"code"];
            [refCharacteristic setObject:@{ @"reference": "#" + subgroupID } forKey:@"valueReference"];
            [refCharacteristic setObject:NO forKey:@"exclude"];

            [characteristics addObject:refCharacteristic];
        }
        else
        {
            var criteria = [_ruleEditor criteriaForRow:current_index];

            if ([criteria count] >= 3)
            {
                var presence = [criteria objectAtIndex:1];

                var rawText = @"";
                if (_currentTextFieldIndex < [_currentTextFields count])
                {
                    var textField = [_currentTextFields objectAtIndex:_currentTextFieldIndex];
                    rawText = [textField stringValue] || @"";
                    _currentTextFieldIndex++;
                }

                var clinicalTerm = [rawText stringByTrimmingCharactersInSet:[CPCharacterSet whitespaceAndNewlineCharacterSet]];
                var hpoTermName = [clinicalTerm isEqualToString:@""] ? @"UNDEFINED" : clinicalTerm;

                var formattedTerm = hpoTermName.toUpperCase().replace(/\s+/g, '_');
                var hpoCodePlaceholder = "[HPO_CODE_FOR_" + formattedTerm + "]";

                var charItem = [CPMutableDictionary dictionary];

                [charItem setObject:@{
                    @"coding": [
                        @{
                        @"system": @"http://snomed.info/sct",
                        @"code": @"8116006",
                        @"display": @"Phänotypisches Merkmal"
                    }
                        ]
                } forKey:@"code"];

                [charItem setObject:@{
                    @"coding": [
                        @{
                        @"system": @"http://human-phenotype-ontology.org",
                        @"code": hpoCodePlaceholder,
                        @"display": hpoTermName
                    }
                        ]
                } forKey:@"valueCodeableConcept"];

                var isExclude = [presence isEqualToString:@"exclusion"];
                [charItem setObject:isExclude forKey:@"exclude"];

                [characteristics addObject:charItem];
            }
        }

        current_index = [subrowIndexes indexGreaterThanIndex:current_index];
    }

    [group setObject:characteristics forKey:@"characteristic"];
    return group;
}

- (void)importFHIRGroup:(id)rootGroup
{
    if (!rootGroup) return;
    try
    {
        _isImportingJSON = YES;

        // 1. Safe clear: dismantle rows in reverse order with includeSubrows:NO
        var count = [_ruleEditor numberOfRows];
        if (count > 0)
        {
            for (var i = count - 1; i >= 0; i--)
            {
                var indexes = [CPIndexSet indexSetWithIndex:i];
                [_ruleEditor removeRowsAtIndexes:indexes includeSubrows:NO];
            }
        }

        // Reset the text-field cache dictionary
        _importedTextFieldsByRow = [CPMutableDictionary dictionary];

        var rootRows = [_ruleEditor _rootRowsArray];
        // rootRows is now empty.

        // 2. Build the recursive tree structure in memory
        var indexWrapper = { value: 0 };
        var rootRow = [self _buildRowObjectFromFHIRGroup:rootGroup targetTextFieldIndex:indexWrapper];

        if (rootRow)
        {
            [rootRows addObject:rootRow];
        }

        [self performSelector:@selector(_enableImporting) withObject:nil afterDelay:0];
    }
    catch (e)
    {
        console.error("[FHIR Error] Exception in structural reconstruction: ", e);
        _isImportingJSON = NO;
    }
}

- (id)_buildRowObjectFromFHIRGroup:(id)group targetTextFieldIndex:(id)indexWrapper
{
    if (!group) return nil;

    var combinationMethod = group.combinationMethod || "all-of";
    var predicateType = (combinationMethod === "any-of") ? CPOrPredicateType : CPAndPredicateType;
    var dispAllAny = (predicateType === CPOrPredicateType) ? @"Any" : @"All";

    // Instantiate and configure the compound group row object
    var rootRow = [[_CPRuleEditorRowObject alloc] init];
    [rootRow setRowType:CPRuleEditorRowTypeCompound];
    [rootRow setCriteria:[CPArray arrayWithObjects:predicateType, @"_logical_text_", nil]];
    [rootRow setDisplayValues:[CPArray arrayWithObjects:dispAllAny, @"of the following are true", nil]];

    // Increment indexWrapper for this Compound row
    indexWrapper.value = indexWrapper.value + 1;

    var subrowsArray = [CPMutableArray array];
    var characteristics = group.characteristic || [];

    for (var i = 0; i < characteristics.length; i++)
    {
        var charItem = characteristics[i];

        // Case A: Recurse into subgroup
        if (charItem.resourceType === "Group" || charItem.characteristic || charItem.combinationMethod)
        {
            var subgroupRow = [self _buildRowObjectFromFHIRGroup:charItem targetTextFieldIndex:indexWrapper];
            if (subgroupRow)
            {
                [subrowsArray addObject:subgroupRow];
            }
        }
        // Case B: Create simple symptom characteristic
        else
        {
            var rawText = @"";
            var valCodeableConcept = charItem.valueCodeableConcept;
            if (valCodeableConcept && valCodeableConcept.coding && valCodeableConcept.coding.length > 0)
            {
                rawText = valCodeableConcept.coding[0].display || @"";
            }

            var presence = charItem.exclude ? @"exclusion" : @"inclusion";
            var dispInclusionExclusion = (presence === @"exclusion") ? @"Must NOT be present (Exclusion)" : @"Must be present (Inclusion)";

            var inputField = [[CPTextField alloc] initWithFrame:CGRectMake(0, 0, 160, 24)];
            [inputField setEditable:YES];
            [inputField setBezeled:YES];
            [inputField setBackgroundColor:[CPColor whiteColor]];
            [inputField setPlaceholderString:@"e.g., Corneal erosion"];
            [inputField setStringValue:rawText];
            [inputField setTarget:self];
            [inputField setAction:@selector(ruleEditorDidChange:)];

            [[CPNotificationCenter defaultCenter] addObserver:self
                                                     selector:@selector(ruleEditorDidChange:)
                                                         name:CPControlTextDidChangeNotification
                                                       object:inputField];

            // Map the input field to its target row index sequentially
            var targetRowIndex = indexWrapper.value;
            [_importedTextFieldsByRow setObject:inputField forKey:[CPNumber numberWithInt:targetRowIndex]];
            
            // Increment indexWrapper for this Simple row
            indexWrapper.value = indexWrapper.value + 1;

            var childRow = [[_CPRuleEditorRowObject alloc] init];
            [childRow setRowType:CPRuleEditorRowTypeSimple];
            [childRow setCriteria:[CPArray arrayWithObjects:@"phenotype", presence, @"_value_field_", nil]];
            [childRow setDisplayValues:[CPArray arrayWithObjects:@"Symptom / Phenotype", dispInclusionExclusion, inputField, nil]];
            [childRow setSubrows:[CPArray array]];

            [subrowsArray addObject:childRow];
        }
    }

    [rootRow setSubrows:subrowsArray];
    return rootRow;
}

- (void)_enableImporting
{
    _isImportingJSON = NO;
    [self updateFHIRGroupRepresentation];
}

// --------------------------------------------------------------------------------
// Tab 2: HPO Browser Data Source & Search Operations
// --------------------------------------------------------------------------------

- (int)numberOfRowsInTableView:(CPTableView)tableView
{
    if (tableView === synonymsTableView) return [_synonyms count];
    if (tableView === xrefsTableView) return [_xrefs count];
    if (tableView === downstreamTableView) return [_downstreamTerms count];
    return 0;
}

- (id)tableView:(CPTableView)tableView objectValueForTableColumn:(CPTableColumn)tableColumn row:(int)row
{
    if (tableView === synonymsTableView) {
        return (row < [_synonyms count]) ? _synonyms[row].label : nil;
    }
    if (tableView === xrefsTableView) {
        return (row < [_xrefs count]) ? _xrefs[row].label : nil;
    }
    if (tableView === downstreamTableView) {
        if (row >= [_downstreamTerms count]) return nil;
        var term = _downstreamTerms[row];
        if ([tableColumn identifier] === @"id") {
            return term.id;
        } else if ([tableColumn identifier] === @"label") {
            return term.label;
        }
    }
    return nil;
}

- (void)tableView:(CPTableView)tableView sortDescriptorsDidChange:(CPArray)oldDescriptors
{
    var arrayToSort = nil;
    if (tableView === synonymsTableView) {
        arrayToSort = _synonyms;
    } else if (tableView === xrefsTableView) {
        arrayToSort = _xrefs;
    } else if (tableView === downstreamTableView) {
        arrayToSort = _downstreamTerms;
    }

    if (!arrayToSort || [arrayToSort count] === 0)
        return;

    var descriptors = [tableView sortDescriptors];
    var mainDescriptor = [descriptors count] > 0 ? [descriptors objectAtIndex:0] : nil;
    if (!mainDescriptor) return;

    var key = [mainDescriptor key];
    var ascending = [mainDescriptor ascending];

    arrayToSort.sort(function(a, b) {
        var valA = a[key];
        var valB = b[key];

        if (valA === undefined) valA = "";
        if (valB === undefined) valB = "";

        if (valA < valB) return ascending ? -1 : 1;
        if (valA > valB) return ascending ? 1 : -1;
        return 0;
    });

    [tableView reloadData];
}

- (void)outlineViewSelectionDidChange:(CPNotification)notification
{
    var selectedRow = [outlineView selectedRow];

    if (selectedRow === -1) {
        _synonyms = [];
        _xrefs = [];
        _downstreamTerms = [];
        [definitionTextView setString:@""];

        [synonymsTableView reloadData];
        [xrefsTableView reloadData];
        [downstreamTableView reloadData];
        return;
    }

    var item = [outlineView itemAtRow:selectedRow];
    var node = item ? [item representedObject] : nil;
    if (!node) return;

    [definitionTextView setString:[node definition] + ' (HP:' + [CPString stringWithFormat:"%07d", node.termId + 0] + ')' || @"No definition available."];
    [self fetchDownstreamForNode:node];
    [self fetchSynonymsForNode:node];
    [self fetchXrefsForNode:node];
}

- (BOOL)outlineView:(CPOutlineView)anOutlineView shouldExpandItem:(id)anItem
{
    var node = anItem ? [anItem representedObject] : nil;
    if (!node || [node isLeaf]) return YES;

    if ([node hasLoadedChildren]) {
        [self syncTreeNode:anItem withModelChildren:[node children]];
        return YES;
    }

    var expandStartTime = [CPDate timeIntervalSinceReferenceDate];
    [node fetchChildrenWithCompletion:function(newChildren) {
        var elapsed = [CPDate timeIntervalSinceReferenceDate] - expandStartTime;
        var animationDuration = 0.25;
        var delay = MAX(0, animationDuration - elapsed + 0.05);

        setTimeout(function() {
            [self syncTreeNode:anItem withModelChildren:newChildren];
            [anOutlineView reloadItem:anItem reloadChildren:YES];
        }, delay * 1000);
    }];

    return YES;
}

// --------------------------------------------------------------------------------
// Web Services Connectivity
// --------------------------------------------------------------------------------

- (void)fetchRoots
{
    var request = [CPURLRequest requestWithURL:"/DBB/hpo/roots"];
    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error) {
        if (!error && data) {
            var json = [CPJSONSerialization JSONObjectWithData:data options:0 error:nil];
            var roots = [CPMutableArray array];
            if (json && json.length) {
                for (var i = 0; i < json.length; i++) {
                    var node = [[HPONode alloc] initWithDict:json[i]];
                    [roots addObject:node];
                }
            }
            _allRoots = roots;
            [treeController setContent:_allRoots];
        } else {
            console.error("Failed to fetch HPO roots: " + error);
        }
    }];
}

- (void)fetchDownstreamForNode:(HPONode)node
{
    if (!node) return;
    var urlString = "/DBB/children/idparent/" + [node termId];
    var request = [CPURLRequest requestWithURL:urlString];
    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
    {
        if (!error && data) {
            var parsed = [CPJSONSerialization JSONObjectWithData:data options:0 error:nil];
            _downstreamTerms = (parsed && parsed.length) ? parsed : [];
        } else {
            _downstreamTerms = [];
        }
        [downstreamTableView reloadData];
    }];
}

- (void)fetchSynonymsForNode:(HPONode)node
{
    if (!node) return;
    var urlString = "/DBB/hpo/synonyms/" + [node termId];
    var request = [CPURLRequest requestWithURL:urlString];
    [CPURLConnection sendAsynchronousRequest:request queue:[CPOperationQueue mainQueue] completionHandler:function(response, data, error) {
        if (!error && data) {
            var parsed = [CPJSONSerialization JSONObjectWithData:data options:0 error:nil];
            _synonyms = (parsed && parsed.length) ? parsed : [];
        } else {
            _synonyms = [];
        }
        [synonymsTableView reloadData];
    }];
}

- (void)fetchXrefsForNode:(HPONode)node
{
    if (!node) return;
    var urlString = "/DBB/hpo/xrefs/" + [node termId];
    var request = [CPURLRequest requestWithURL:urlString];
    [CPURLConnection sendAsynchronousRequest:request queue:[CPOperationQueue mainQueue] completionHandler:function(response, data, error) {
        if (!error && data) {
            var parsed = [CPJSONSerialization JSONObjectWithData:data options:0 error:nil];
            _xrefs = (parsed && parsed.length) ? parsed : [];
        } else {
            _xrefs = [];
        }
        [xrefsTableView reloadData];
    }];
}

// --------------------------------------------------------------------------------
// Search & Hierarchy Expansion Algorithms
// --------------------------------------------------------------------------------

- (void)searchAction:(id)sender
{
    var searchString = [sender stringValue];
    var isNameOnly = [_nameOnlyCheckbox state] === CPOnState;
    [self performSearchForString:searchString isNameOnly:isNameOnly];
}

- (void)performSearchForString:(CPString)searchString isNameOnly:(BOOL)isNameOnly
{
    if (!searchString || [searchString length] === 0)
    {
        [treeController setSelectionIndexPaths:[]];
        _matchedIndexPaths = [];
        _currentMatchIndex = -1;
        [_searchStatusLabel setStringValue:@""];
        return;
    }

    [_searchStatusLabel setStringValue:@"Searching..."];
    [self startPulsatingAnimation];

    var urlString = "/DBB/hpo/search/" + encodeURIComponent(searchString) + "?nameOnly=" + (isNameOnly ? "1" : "0");
    var request = [CPURLRequest requestWithURL:urlString];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
     {
        [self stopPulsatingAnimation];
        if (!error && data)
        {
            var json = [CPJSONSerialization JSONObjectWithData:data options:0 error:nil];
            [self expandAndSelectPaths:json];
        }
        else
        {
            [_searchStatusLabel setStringValue:@"Error"];
        }
     }];
}

- (void)resolvePath:(CPArray)nodeIds currentIndex:(int)index currentModels:(CPArray)models baseIndexPath:(CPIndexPath)indexPath completion:(Function)callback
{
    if (!nodeIds || index >= nodeIds.length) {
        callback(indexPath);
        return;
    }

    var targetId = parseInt(nodeIds[index], 10);
    var foundModelIndex = -1;
    var foundModel = nil;

    for (var i = 0; i < [models count]; i++) {
        if ([models[i] termId] === targetId) {
            foundModelIndex = i;
            foundModel = models[i];
            break;
        }
    }

    if (!foundModel) {
        callback(nil);
        return;
    }

    var nextIndexPath = indexPath ? [indexPath indexPathByAddingIndex:foundModelIndex] : [CPIndexPath indexPathWithIndex:foundModelIndex];

    if (index === nodeIds.length - 1) {
        callback(nextIndexPath);
    } else {
        [foundModel fetchChildrenWithCompletion:function(newChildren) {
            var treeNode = [[treeController arrangedObjects] descendantNodeAtIndexPath:nextIndexPath];
            if (treeNode) {
                [self syncTreeNode:treeNode withModelChildren:newChildren];
            }
            [self resolvePath:nodeIds currentIndex:(index + 1) currentModels:newChildren baseIndexPath:nextIndexPath completion:callback];
        }];
    }
}

- (void)expandAndSelectPaths:(CPArray)searchResults
{
    if (!searchResults || !searchResults.length)
    {
        [treeController setSelectionIndexPaths:[]];
        _matchedIndexPaths = [];
        _currentMatchIndex = -1;
        [_searchStatusLabel setStringValue:@"0 hits"];
        return;
    }

    var targetIndexPaths = [CPMutableArray array];
    var pendingPaths = searchResults.length;

    for (var i = 0; i < searchResults.length; i++)
    {
        var nodeIds = searchResults[i].path;
        [self resolvePath:nodeIds
             currentIndex:0
            currentModels:_allRoots
            baseIndexPath:nil
               completion:function(finalIndexPath) {
            if (finalIndexPath)
            {
                [targetIndexPaths addObject:finalIndexPath];
            }
            pendingPaths--;

            if (pendingPaths === 0)
            {
                _matchedIndexPaths = targetIndexPaths;
                _currentMatchIndex = 0;

                setTimeout(function() {
                    [self updateSelectionToCurrentMatch];
                }, 50);
            }
        }];
    }
}

- (void)updateSelectionToCurrentMatch
{
    if (!_matchedIndexPaths || [_matchedIndexPaths count] === 0)
    {
        [_searchStatusLabel setStringValue:@"0 hits"];
        return;
    }

    var path = _matchedIndexPaths[_currentMatchIndex];
    var partialPath = [CPIndexPath indexPathWithIndex:[path indexAtPosition:0]];

    for (var level = 1; level < [path length]; level++)
    {
        var treeNode = [[treeController arrangedObjects] descendantNodeAtIndexPath:partialPath];
        if (treeNode)
            [outlineView expandItem:treeNode];

        partialPath = [partialPath indexPathByAddingIndex:[path indexAtPosition:level]];
    }

    [treeController setSelectionIndexPath:path];
    [_searchStatusLabel setStringValue:(_currentMatchIndex + 1) + @" of " + [_matchedIndexPaths count]];

    setTimeout(function() {
        var node = [[treeController arrangedObjects] descendantNodeAtIndexPath:path];
        if (node) {
            var rowIndex = [outlineView rowForItem:node];
            if (rowIndex >= 0) {
                [outlineView scrollRowToVisible:rowIndex];
            }
        }
    }, 300);
}

- (void)prevMatch:(id)sender
{
    if (!_matchedIndexPaths || _matchedIndexPaths.length === 0) return;
    _currentMatchIndex--;
    if (_currentMatchIndex < 0)
        _currentMatchIndex = _matchedIndexPaths.length - 1;
    [self updateSelectionToCurrentMatch];
}

- (void)nextMatch:(id)sender
{
    if (!_matchedIndexPaths || _matchedIndexPaths.length === 0) return;
    _currentMatchIndex++;
    if (_currentMatchIndex >= _matchedIndexPaths.length)
        _currentMatchIndex = 0;
    [self updateSelectionToCurrentMatch];
}

- (void)doubleClickDownstream:(id)sender
{
    var clickedRow = [downstreamTableView clickedRow];
    if (clickedRow < 0 || clickedRow >= [_downstreamTerms count]) return;

    var term = _downstreamTerms[clickedRow];
    var formattedId = "HP:" + [CPString stringWithFormat:"%07d", term.id + 0];

    [_searchField setStringValue:formattedId];
    [_nameOnlyCheckbox setState:CPOffState];
    [self performSearchForString:formattedId isNameOnly:NO];
}

- (void)exportDownstream:(id)sender
{
    if (!_downstreamTerms || [_downstreamTerms count] === 0) return;

    var textToExport = "";
    for (var i = 0; i < [_downstreamTerms count]; i++) {
        var termId = _downstreamTerms[i].id;
        var formatted = "HP:" + [CPString stringWithFormat:"%07d", termId + 0];
        textToExport += formatted + "\n";
    }

    if (!_exportPopover)
    {
        _exportPopover = [CPPopover new];
        [_exportPopover setBehavior:CPPopoverBehaviorTransient];
        [_exportPopover setAppearance:CPPopoverAppearanceMinimal];
        [_exportPopover setAnimates:YES];

        var containerView = [[CPView alloc] initWithFrame:CGRectMake(0, 0, 250, 350)];
        var scrollView = [[CPScrollView alloc] initWithFrame:[containerView bounds]];
        [scrollView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
        [scrollView setAutohidesScrollers:YES];

        _exportTextView = [[CPTextView alloc] initWithFrame:[scrollView bounds]];
        [_exportTextView setAutoresizingMask:CPViewWidthSizable];
        [_exportTextView setEditable:NO];
        [_exportTextView setSelectable:YES];

        [scrollView setDocumentView:_exportTextView];
        [containerView addSubview:scrollView];

        var myViewController = [CPViewController new];
        [myViewController setView:containerView];
        [_exportPopover setContentViewController:myViewController];
    }

    [_exportTextView setString:textToExport];
    [_exportPopover showRelativeToRect:[sender bounds] ofView:sender preferredEdge:CPMinYEdge];

    window.setTimeout(function() {
        [_exportTextView selectAll:self];
    }, 50);
}

- (void)syncTreeNode:(CPTreeNode)treeNode withModelChildren:(CPArray)newChildren
{
    if (!treeNode) return;

    var mutableChildNodes = [treeNode mutableChildNodes];

    if ([mutableChildNodes count] > 0)
    {
        var firstChildObj = [[mutableChildNodes objectAtIndex:0] representedObject];
        if ([firstChildObj name] !== @"Loading...") {
            return;
        }
    } else if ([mutableChildNodes count] === 0 && [newChildren count] === 0) {
        return;
    }

    [mutableChildNodes removeAllObjects];

    for (var i = 0; i < [newChildren count]; i++) {
        var childModel = newChildren[i];
        var childTreeNode = [[CPTreeNode alloc] initWithRepresentedObject:childModel];

        if (![childModel isLeaf] && [[childModel children] count] > 0) {
            var dummyModel = [[childModel children] objectAtIndex:0];
            var dummyTreeNode = [[CPTreeNode alloc] initWithRepresentedObject:dummyModel];
            [[childTreeNode mutableChildNodes] addObject:dummyTreeNode];
        }

        [mutableChildNodes addObject:childTreeNode];
    }
}

// --------------------------------------------------------------------------------
// Status Pulse Animations
// --------------------------------------------------------------------------------

- (void)startPulsatingAnimation
{
    [_searchStatusLabel setWantsLayer:YES];
    var layer = [_searchStatusLabel layer];
    [layer setDelegate:self];

    var pulseAnimation = [CABasicAnimation animationWithKeyPath:@"searchAlphaValue"];
    pulseAnimation._animationID = "searchPulse";
    [pulseAnimation setDelegate:self];
    [pulseAnimation setFromValue:1.0];
    [pulseAnimation setToValue:0.2];
    [pulseAnimation setDuration:0.6];
    [layer addAnimation:pulseAnimation forKey:@"searchAlphaValue"];
}

- (void)stopPulsatingAnimation
{
    [[_searchStatusLabel layer] removeAnimationForKey:@"searchAlphaValue"];
    [_searchStatusLabel setAlphaValue:1.0];
}

- (void)setSearchAlphaValue:(float)val
{
    [_searchStatusLabel setAlphaValue:val];
}

- (void)animationDidStop:(CAAnimation)anim finished:(BOOL)finished
{
    if (!finished) return;
    if (anim._animationID === @"searchPulse") {
        var currentOpacity = [_searchStatusLabel alphaValue];
        var fromVal = (currentOpacity < 0.5) ? 0.2 : 1.0;
        var toVal   = (currentOpacity < 0.5) ? 1.0 : 0.2;

        var layer = [_searchStatusLabel layer];
        var pulseAnimation = [CABasicAnimation animationWithKeyPath:@"searchAlphaValue"];
        pulseAnimation._animationID = "searchPulse";
        [pulseAnimation setDelegate:self];
        [pulseAnimation setFromValue:fromVal];
        [pulseAnimation setToValue:toVal];
        [pulseAnimation setDuration:0.6];
        [layer addAnimation:pulseAnimation forKey:@"searchAlphaValue"];
    }
}

@end


// --------------------------------------------------------------------------------
// Custom HPO Node Implementation
// --------------------------------------------------------------------------------

@implementation HPONode : CPObject
{
    int      termId            @accessors(property=termId);
    CPString name              @accessors(property=name);
    CPString definition        @accessors(property=definition);
    BOOL     isLeaf            @accessors(property=isLeaf);
    CPArray  children;
    BOOL     hasLoadedChildren @accessors(property=hasLoadedChildren);
    BOOL     _isFetching;
    CPArray  _fetchCallbacks;
}

- (id)initWithDict:(JSObject)dict
{
    self = [super init];
    if (self)
    {
        termId = dict.id;
        name = dict.label;
        definition = dict.definition || dict.label;
        isLeaf = (dict.is_leaf == 1);

        if (!isLeaf)
        {
            var dummyNode = [[HPONode alloc] initAsDummy];
            children = [dummyNode];
        }
        else
        {
            children = [];
        }
        hasLoadedChildren = NO;
    }
    return self;
}

- (id)initAsDummy
{
    self = [super init];
    if (self)
    {
        name = @"Loading...";
        definition = @"";
        isLeaf = YES;
        children = [];
        hasLoadedChildren = YES;
    }
    return self;
}

- (void)setChildren:(CPArray)someChildren
{
    [self willChangeValueForKey:@"children"];
    children = someChildren;
    [self didChangeValueForKey:@"children"];
}

- (CPArray)children
{
    return children;
}

- (void)fetchChildrenWithCompletion:(Function)completion
{
    if (hasLoadedChildren) {
        if (completion) completion(children);
        return;
    }

    if (!_fetchCallbacks) _fetchCallbacks = [];
    if (completion) [_fetchCallbacks addObject:completion];

    if (_isFetching) return;
    _isFetching = YES;

    var urlString = "/DBB/hpo/children/" + termId;
    var request = [CPURLRequest requestWithURL:urlString];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error) {
        _isFetching = NO;

        if (!error && data)
        {
            var json = [CPJSONSerialization JSONObjectWithData:data options:0 error:nil];
            var newChildren = [CPMutableArray array];

            if (json && json.length) {
                for (var i = 0; i < json.length; i++) {
                    var childNode = [[HPONode alloc] initWithDict:json[i]];
                    [newChildren addObject:childNode];
                }
            }

            hasLoadedChildren = YES;
            [self setChildren:newChildren];

            var callbacksToRun = [_fetchCallbacks copy];
            [_fetchCallbacks removeAllObjects];
            for (var i = 0; i < callbacksToRun.length; i++) {
                callbacksToRun[i](newChildren);
            }
        } else {
            var callbacksToRun = [_fetchCallbacks copy];
            [_fetchCallbacks removeAllObjects];
            for (var i = 0; i < callbacksToRun.length; i++) {
                callbacksToRun[i]([]);
            }
        }
    }];
}

@end


// --------------------------------------------------------------------------------
// JSON Utilities
// --------------------------------------------------------------------------------

@implementation CPJSONSerialization : CPObject

+ (id)JSONObjectWithData:(CPString)data options:(int)options error:(id)error
{
    if (!data || [data length] === 0) return nil;
    try {
        return JSON.parse(data);
    } catch (e) {
        return nil;
    }
}

+ (CPString)dataWithJSONObject:(id)object options:(int)options error:(id)error
{
    if (!object) return nil;
    try {
        return JSON.stringify(object);
    } catch (e) {
        return nil;
    }
}

@end
