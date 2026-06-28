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
// FHIRCriteriaNode (Structured MVC Row Model)
// --------------------------------------------------------------------------------

@implementation FHIRCriteriaNode : CPObject
{
    CPRuleEditorRowType _rowType           @accessors(property=rowType);
    CPMutableArray      _subrows           @accessors(property=subrows);
    CPArray             _criteria          @accessors(property=criteria);
    CPArray             _displayValues     @accessors(property=displayValues);

    CPString            _symptomText;
    BOOL                _exclude;
    CPString            _combinationMethod;
    int                 _indentation       @accessors(property=indentation);

    CPTextField         _textField         @accessors(property=textField);
}

- (id)init
{
    self = [super init];
    if (self)
    {
        _subrows = [CPMutableArray array];
        _criteria = [CPArray array];
        _displayValues = [CPArray array];
        _rowType = CPRuleEditorRowTypeSimple;
        _symptomText = @"";
        _exclude = NO;
        _combinationMethod = @"all-of";
        _indentation = 0;
    }
    return self;
}

- (CPArray)subrows_none
{
    return [];
}

- (void)setSymptomText:(CPString)text
{
    if (_symptomText !== text)
    {
        _symptomText = text;
        [self updateCriteriaAndDisplayValues];
    }
}

- (CPString)symptomText
{
    return _symptomText;
}

- (void)setExclude:(BOOL)exclude
{
    if (_exclude !== exclude)
    {
        _exclude = exclude;
        [self updateCriteriaAndDisplayValues];
    }
}

- (BOOL)exclude
{
    return _exclude;
}

- (void)setCombinationMethod:(CPString)method
{
    if (_combinationMethod !== method)
    {
        _combinationMethod = method;
        [self updateCriteriaAndDisplayValues];
    }
}

- (CPString)combinationMethod
{
    return _combinationMethod;
}

- (void)setCriteria:(CPArray)criteria
{
    if (_criteria !== criteria)
    {
        _criteria = criteria;

        if (_rowType === CPRuleEditorRowTypeCompound)
        {
            if ([_criteria count] > 0)
            {
                var first = [_criteria objectAtIndex:0];
                _combinationMethod = (first === CPOrPredicateType) ? @"any-of" : @"all-of";
            }
        }
        else
        {
            if ([_criteria count] > 1)
            {
                var second = [_criteria objectAtIndex:1];
                _exclude = [second isEqualToString:@"exclusion"];
            }
        }
    }
}

- (void)updateCriteriaAndDisplayValues
{
    if (_rowType === CPRuleEditorRowTypeCompound)
    {
        var predicateType = (_combinationMethod === @"any-of") ? CPOrPredicateType : CPAndPredicateType;
        var dispAllAny = (_combinationMethod === @"any-of") ? @"Any" : @"All";

        [self setCriteria:[CPArray arrayWithObjects:predicateType, @"_logical_text_", nil]];
        [self setDisplayValues:[CPArray arrayWithObjects:dispAllAny, @"of the following are true", nil]];
    }
    else
    {
        var presence = _exclude ? @"exclusion" : @"inclusion";
        var dispPresence = _exclude ? @"Must NOT be present (Exclusion)" : @"Must be present (Inclusion)";

        [self setCriteria:[CPArray arrayWithObjects:@"phenotype", presence, @"_value_field_", nil]];
        [self setDisplayValues:[CPArray arrayWithObjects:@"Symptom / Phenotype", dispPresence, @"_value_field_", nil]];
    }
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

- (void)_updateSliceRows
{
    [super _updateSliceRows];

    var count = [self numberOfRows];
    for (var i = 0; i < count; i++)
    {
        var slice = [_slices objectAtIndex:i];
        var depth = [self depthOfRowAtIndex:i];
        [slice setIndentation:depth];
    }
}

- (int)depthOfRowAtIndex:(int)rowIndex
{
    var node = [self nodeAtRowIndex:rowIndex];
    return node ? [node indentation] : 0;
}

// Add this helper method so 'self' can resolve it during depth queries
- (id)nodeAtRowIndex:(int)rowIndex
{
    if (rowIndex < 0 || rowIndex >= [self numberOfRows])
        return nil;

    var rowCache = [self _rowCacheForIndex:rowIndex];
    return rowCache ? [rowCache rowObject] : nil;
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
        var node = [_controller nodeAtRowIndex:row];
        if (node)
        {
            var cachedField = [node textField];
            if (cachedField)
            {
                return cachedField;
            }

            var inputField = [[CPTextField alloc] initWithFrame:CGRectMake(0, 0, 160, 24)];
            [inputField setEditable:YES];
            [inputField setBezeled:YES];
            [inputField setBackgroundColor:[CPColor whiteColor]];
            [inputField setPlaceholderString:@"e.g., Corneal erosion"];
            [inputField setStringValue:[node symptomText]];
            [inputField setTarget:_controller];
            [inputField setAction:@selector(ruleEditorDidChange:)];

            inputField.node = node;

            [[CPNotificationCenter defaultCenter] addObserver:_controller
                                                     selector:@selector(ruleEditorDidChange:)
                                                         name:CPControlTextDidChangeNotification
                                                       object:inputField];

            [node setTextField:inputField];
            return inputField;
        }
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

    CPTextView           _jsonTextView;
    CPPopover            _jsonPopover;
    CPTextView           _popoverTextView;

    CPMutableArray       _rootNodes          @accessors(property=rootNodes);
    BOOL                 _isImportingJSON;

    // TAB 2: HPO Tree Browser
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

    _tabView = [[CPTabView alloc] initWithFrame:bounds];
    [_tabView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [contentView addSubview:_tabView];

    _isImportingJSON = NO;

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
    [_modelPopUpButton addItemWithTitle:@"mock-extractor"];
    [[settingsBox contentView] addSubview:_modelPopUpButton];

    _extractButton = [[CPButton alloc] initWithFrame:CGRectMake(10, 48, CGRectGetWidth([settingsBox bounds]) - 20, 28)];
    [_extractButton setTitle:@"Extract FHIR Criteria"];
    [_extractButton setTarget:self];
    [_extractButton setAction:@selector(extractFHIRCriteriaAction:)];
    [_extractButton setAutoresizingMask:CPViewWidthSizable];
    [[settingsBox contentView] addSubview:_extractButton];
    [leftContainer addSubview:settingsBox];

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

    [_ruleEditor setRowClass:[FHIRCriteriaNode class]];
    [_ruleEditor setRowTypeKeyPath:@"rowType"];
    [_ruleEditor setSubrowsKeyPath:@"subrows_none"];
    [_ruleEditor setCriteriaKeyPath:@"criteria"];
    [_ruleEditor setDisplayValuesKeyPath:@"displayValues"];

    [self setRootNodes:[CPMutableArray array]];
    [_ruleEditor bind:@"rows" toObject:self withKeyPath:@"rootNodes" options:nil];

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

- (id)convertCustomJSONToFHIRGroup:(id)customNode
{
    if (!customNode) return nil;

    var group = {};
    group.resourceType = "Group";
    group.combinationMethod = customNode.combinationMethod || "all-of";
    
    var customCharacteristics = customNode.characteristics || customNode.characteristic || [];
    var fhirCharacteristics = [];

    for (var i = 0; i < customCharacteristics.length; i++)
    {
        var item = customCharacteristics[i];
        
        if (item.subgroup)
        {
            var subGroup = [self convertCustomJSONToFHIRGroup:item.subgroup];
            if (subGroup)
            {
                fhirCharacteristics.push(subGroup);
            }
        }
        else if (item.symptom)
        {
            var sym = item.symptom;
            var fhirChar = {
                "exclude": sym.exclude ? true : false,
                "valueCodeableConcept": {
                    "coding": [{
                        "system": "http://human-phenotype-ontology.org",
                        "code": "",
                        "display": sym.label || ""
                    }]
                }
            };
            fhirCharacteristics.push(fhirChar);
        }
        else if (item.characteristic || item.resourceType === "Group")
        {
            var subGroup = [self convertCustomJSONToFHIRGroup:item];
            if (subGroup)
            {
                fhirCharacteristics.push(subGroup);
            }
        }
        else
        {
            fhirCharacteristics.push(item);
        }
    }

    group.characteristic = fhirCharacteristics;
    return group;
}

// --------------------------------------------------------------------------------
// Hierarchy Helpers
// --------------------------------------------------------------------------------

- (FHIRCriteriaNode)nodeAtRowIndex:(int)rowIndex
{
    if (rowIndex < 0 || rowIndex >= [_ruleEditor numberOfRows])
        return nil;

    var rowCache = [_ruleEditor _rowCacheForIndex:rowIndex];
    return rowCache ? [rowCache rowObject] : nil;
}

- (id)textFieldForRow:(int)row
{
    var node = [self nodeAtRowIndex:row];
    return node ? [node textField] : nil;
}

// --------------------------------------------------------------------------------
// Tab 1: FHIR Criterion Flattened Insertion & Model Helpers
// --------------------------------------------------------------------------------

- (void)flattenNode:(FHIRCriteriaNode)node depth:(int)depth intoArray:(CPMutableArray)array
{
    if (!node) return;

    [node setIndentation:depth];
    [array addObject:node];

    var subrows = [node subrows] || [];
    for (var i = 0; i < [subrows count]; i++)
    {
        [self flattenNode:subrows[i] depth:depth + 1 intoArray:array];
    }
}

- (void)insertNode:(FHIRCriteriaNode)newNode
{
    var selectedRows = [_ruleEditor selectedRowIndexes];
    var selectedIndex = [selectedRows count] > 0 ? [selectedRows lastIndex] : CPNotFound;

    if (selectedIndex === CPNotFound)
    {
        [newNode setIndentation:0];
        [[self mutableArrayValueForKey:@"rootNodes"] addObject:newNode];
        return;
    }

    var selectedNode = [_rootNodes objectAtIndex:selectedIndex];
    var targetDepth = [selectedNode indentation];

    if ([selectedNode rowType] === CPRuleEditorRowTypeCompound)
    {
        targetDepth = targetDepth + 1;
    }

    [newNode setIndentation:targetDepth];
    [[self mutableArrayValueForKey:@"rootNodes"] insertObject:newNode atIndex:selectedIndex + 1];
}

- (void)addSimpleRule:(id)sender
{
    var newNode = [[FHIRCriteriaNode alloc] init];
    [newNode setRowType:CPRuleEditorRowTypeSimple];
    [newNode updateCriteriaAndDisplayValues];

    [self insertNode:newNode];
}

- (void)addGroupRule:(id)sender
{
    var newNode = [[FHIRCriteriaNode alloc] init];
    [newNode setRowType:CPRuleEditorRowTypeCompound];
    [newNode setCombinationMethod:@"all-of"];
    [newNode updateCriteriaAndDisplayValues];

    [self insertNode:newNode];

    // Automatically append an initial simple row inside the new group
    var childNode = [[FHIRCriteriaNode alloc] init];
    [childNode setRowType:CPRuleEditorRowTypeSimple];
    [childNode updateCriteriaAndDisplayValues];
    [childNode setIndentation:[newNode indentation] + 1];

    var groupIndex = [_rootNodes indexOfObjectIdenticalTo:newNode];
    if (groupIndex !== CPNotFound)
    {
        [[self mutableArrayValueForKey:@"rootNodes"] insertObject:childNode atIndex:groupIndex + 1];
    }
}

- (void)resetEditor:(id)sender
{
    var newNode = [[FHIRCriteriaNode alloc] init];
    [newNode setRowType:CPRuleEditorRowTypeSimple];
    [newNode updateCriteriaAndDisplayValues];

    [self setRootNodes:[CPMutableArray arrayWithObject:newNode]];
    [self updateFHIRGroupRepresentation];
}

- (void)ruleEditorDidChange:(id)sender
{
    if (_isImportingJSON)
        return;

    var control = sender;
    if ([sender isKindOfClass:[CPNotification class]])
    {
        control = [sender object];
    }

    if ([control isKindOfClass:[CPTextField class]] && control.node)
    {
        [control.node setSymptomText:[control stringValue]];
    }

    [self updateFHIRGroupRepresentation];
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
                
                // Normalise hierarchy payload formats if custom fields exist
                if (parsedData && (parsedData.characteristics || parsedData.combinationMethod)) {
                    parsedData = [self convertCustomJSONToFHIRGroup:parsedData];
                }
                
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
        var rootGroup = [self compileGroupFromFlatNodes:_rootNodes];
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

- (CPMutableDictionary)compileGroupFromFlatNodes:(CPArray)flatNodes
{
    if ([flatNodes count] === 0) return [CPMutableDictionary dictionary];

    // Reconstruct standard hierarchical structure from flat elements
    var pseudoRoot = [[FHIRCriteriaNode alloc] init];
    [pseudoRoot setRowType:CPRuleEditorRowTypeCompound];
    [pseudoRoot setCombinationMethod:@"all-of"];

    var stack = [pseudoRoot];

    for (var i = 0; i < [flatNodes count]; i++)
    {
        var node = flatNodes[i];
        [[node subrows] removeAllObjects];

        var depth = [node indentation];

        while (stack.length > depth + 1)
        {
            stack.pop();
        }

        var parent = stack[stack.length - 1];
        [[parent subrows] addObject:node];
        stack.push(node);
    }

    var containedArray = [CPMutableArray array];
    var subgroupCounter = { value: 0 };
    var rootGroup = [self compileGroupFromNode:pseudoRoot containedArray:containedArray subgroupCounter:subgroupCounter];

    [rootGroup setObject:@"Group" forKey:@"resourceType"];
    [rootGroup setObject:@"eligibility-criteria" forKey:@"id"];
    [rootGroup setObject:@"active" forKey:@"status"];
    [rootGroup setObject:@"definitional" forKey:@"membership"];
    [rootGroup setObject:@"person" forKey:@"type"];

    var rootCombMethod = "all-of";
    if ([flatNodes count] === 1 && [[flatNodes objectAtIndex:0] rowType] == CPRuleEditorRowTypeCompound)
    {
        rootCombMethod = [[flatNodes objectAtIndex:0] combinationMethod] || "all-of";
    }
    [rootGroup setObject:rootCombMethod forKey:@"combinationMethod"];

    if ([containedArray count] > 0)
    {
        [rootGroup setObject:containedArray forKey:@"contained"];
    }

    return rootGroup;
}

- (CPMutableDictionary)compileGroupFromNode:(FHIRCriteriaNode)node containedArray:(CPMutableArray)containedArray subgroupCounter:(id)subgroupCounter
{
    var group = [CPMutableDictionary dictionary];
    [group setObject:@"Group" forKey:@"resourceType"];

    var subrows = [node subrows] || [];
    var characteristics = [CPMutableArray array];

    for (var i = 0; i < [subrows count]; i++)
    {
        var childNode = subrows[i];

        if ([childNode rowType] === CPRuleEditorRowTypeCompound)
        {
            subgroupCounter.value = subgroupCounter.value + 1;
            var subgroupID = "subgroup-" + subgroupCounter.value;

            var subGroup = [self compileGroupFromNode:childNode containedArray:containedArray subgroupCounter:subgroupCounter];
            [subGroup setObject:subgroupID forKey:@"id"];
            [subGroup setObject:@"conceptual" forKey:@"membership"];
            [subGroup setObject:@"person" forKey:@"type"];
            [subGroup setObject:[childNode combinationMethod] forKey:@"combinationMethod"];

            [containedArray addObject:subGroup];

            var refCharacteristic = [CPMutableDictionary dictionary];
            [refCharacteristic setObject:@{ @"text": @"Logical subgroup" } forKey:@"code"];
            [refCharacteristic setObject:@{ @"reference": "#" + subgroupID } forKey:@"valueReference"];
            [refCharacteristic setObject:NO forKey:@"exclude"];

            [characteristics addObject:refCharacteristic];
        }
        else
        {
            var rawText = [childNode symptomText] || @"";
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

            [charItem setObject:[childNode exclude] forKey:@"exclude"];

            [characteristics addObject:charItem];
        }
    }

    [group setObject:characteristics forKey:@"characteristic"];
    return group;
}

- (FHIRCriteriaNode)nodeFromFHIRGroup:(id)group
{
    if (!group) return nil;

    var node = [[FHIRCriteriaNode alloc] init];
    [node setRowType:CPRuleEditorRowTypeCompound];
    [node setCombinationMethod:group.combinationMethod || @"all-of"];

    var characteristics = group.characteristic || [];
    for (var i = 0; i < characteristics.length; i++)
    {
        var charItem = characteristics[i];
        if (charItem.resourceType === "Group" || charItem.characteristic || charItem.combinationMethod)
        {
            var childNode = [self nodeFromFHIRGroup:charItem];
            if (childNode)
            {
                [[node subrows] addObject:childNode];
            }
        }
        else
        {
            var childNode = [[FHIRCriteriaNode alloc] init];
            [childNode setRowType:CPRuleEditorRowTypeSimple];
            [childNode setExclude:charItem.exclude ? YES : NO];

            var rawText = @"";
            var valCodeableConcept = charItem.valueCodeableConcept;
            if (valCodeableConcept && valCodeableConcept.coding && valCodeableConcept.coding.length > 0)
            {
                rawText = valCodeableConcept.coding[0].display || @"";
            }
            [childNode setSymptomText:rawText];
            [[node subrows] addObject:childNode];
        }
    }

    [node updateCriteriaAndDisplayValues];
    return node;
}

- (id)_flattenFHIRGroup:(id)group
{
    if (!group) return nil;

    var flattenedCharacteristics = [];
    var characteristics = group.characteristic || [];

    for (var i = 0; i < characteristics.length; i++)
    {
        var charItem = characteristics[i];
        var isSubgroup = (charItem.resourceType === "Group" || charItem.characteristic || charItem.combinationMethod);

        if (isSubgroup)
        {
            var flattenedSubgroup = [self _flattenFHIRGroup:charItem];

            if (flattenedSubgroup.combinationMethod === group.combinationMethod)
            {
                var subCharacteristics = flattenedSubgroup.characteristic || [];
                for (var j = 0; j < subCharacteristics.length; j++)
                {
                    flattenedCharacteristics.push(subCharacteristics[j]);
                }
            }
            else
            {
                flattenedCharacteristics.push(flattenedSubgroup);
            }
        }
        else
        {
            flattenedCharacteristics.push(charItem);
        }
    }

    group.characteristic = flattenedCharacteristics;
    return group;
}

- (void)importFHIRGroup:(id)rootGroup
{
    if (!rootGroup) return;
    try
    {
        _isImportingJSON = YES;

        var flattenedGroup = [self _flattenFHIRGroup:rootGroup];
        var rootNode = [self nodeFromFHIRGroup:flattenedGroup];

        var flatList = [CPMutableArray array];
        if (rootNode)
        {
            var combinationMethod = flattenedGroup.combinationMethod || "all-of";
            if (combinationMethod === "any-of")
            {
                [self flattenNode:rootNode depth:0 intoArray:flatList];
            }
            else
            {
                var children = [rootNode subrows];
                for (var i = 0; i < [children count]; i++)
                {
                    [self flattenNode:children[i] depth:0 intoArray:flatList];
                }
            }
        }

        [self setRootNodes:flatList];

        [self performSelector:@selector(_enableImporting) withObject:nil afterDelay:0];
    }
    catch (e)
    {
        console.error("[FHIR Error] Exception in structural reconstruction: ", e);
        _isImportingJSON = NO;
    }
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
