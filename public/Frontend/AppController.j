/*
 * AppController.j
 * Integrated FHIR R6 Eligibility Criteria Editor, HPO Tree Browser & Phenopacket Extractor
 */

@import <Foundation/Foundation.j>
@import <AppKit/AppKit.j>

// --------------------------------------------------------------------------------
// HPOOutlineView Subclass (Supports dragging while keeping TreeController Bindings)
// --------------------------------------------------------------------------------

@implementation HPOOutlineView : CPOutlineView

- (void)mouseDragged:(CPEvent)anEvent
{
    var selectedRow = [self selectedRow];
    if (selectedRow === -1) return;

    var item = [self itemAtRow:selectedRow];  // CPTreeNode wrapping the model when bound
    var node = item ? [item representedObject] : nil; // HPONode model object
    if (!node || [node name] === @"Loading...") return;

    var termId = [node termId];
    var formattedId = "HP:" + [CPString stringWithFormat:"%07d", termId + 0];

    // Safely wrap in CPDictionary to avoid plist serialization exceptions
    var dict = [CPDictionary dictionaryWithObjectsAndKeys:
                    formattedId, @"code",
                [node name], @"display"
    ];

    var pboard = [CPPasteboard pasteboardWithName:CPDragPboard];
    [pboard declareTypes:[CPArray arrayWithObjects:@"HPOTermPboardType", CPStringPboardType, nil] owner:self];
    [pboard setPropertyList:dict forType:@"HPOTermPboardType"];
    [pboard setString:formattedId forType:CPStringPboardType];

    // Create a styled, visible drag view with a background color
    var dragView = [[CPView alloc] initWithFrame:CGRectMake(0, 0, 150, 20)];
    [dragView setBackgroundColor:[CPColor colorWithRed:0.0 green:0.5 blue:0.7 alpha:0.85]];

    // Add a text label inside the drag view to represent the term being dragged
    var dragLabel = [[CPTextField alloc] initWithFrame:CGRectMake(5, 2, 140, 16)];
    [dragLabel setStringValue:[node name]];
    [dragLabel setTextColor:[CPColor whiteColor]];
    [dragLabel setFont:[CPFont systemFontOfSize:10.0]];
    [dragView addSubview:dragLabel];

    [self dragView:dragView
                at:CGPointMakeZero()
            offset:CGSizeMakeZero()
             event:anEvent
        pasteboard:pboard
            source:self
         slideBack:YES];
}

@end

// Helper to allow native JS object serialization to work nicely in Cappuccino
@implementation CPDictionary (JSONHelper)
- (id)JSObject
{
    var obj = {};
    var keys = [self allKeys];
    for (var i = 0; i < [keys count]; i++)
    {
        var key = [keys objectAtIndex:i];
        var val = [self objectForKey:key];

        if (val && val.isa && [val respondsToSelector:@selector(JSObject)])
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
        if (val && val.isa && [val respondsToSelector:@selector(JSObject)])
            arr.push([val JSObject]);
        else
            arr.push(val);
    }
    return arr;
}
@end

// --------------------------------------------------------------------------------
// Category for Custom Token Customization (HPO Code + Label Styling via DOM)
// --------------------------------------------------------------------------------

@implementation _CPTokenFieldToken (HPOCustomization)

- (CGSize)_minimumFrameSize
{
    var minSize = [self currentValueForThemeAttribute:@"min-size"],
    contentInset = [self currentValueForThemeAttribute:@"content-inset"];

    var size = CGSizeMake(0, 18); // Compact 18px height to fit cleanly in the 28px Rule Editor row
    var rep = [self representedObject];
    if (rep && rep.code)
    {
        var codeWidth = [rep.code sizeWithFont:[CPFont boldSystemFontOfSize:8.0]].width + 10;

        var displayText = rep.display || @"";
        if (displayText.length > 10) {
            displayText = [displayText substringToIndex:10] + @"...";
        }
        var textWidth = [displayText sizeWithFont:[CPFont systemFontOfSize:9.0]].width + 6;
        size.width = codeWidth + textWidth + 24; // Sleek and compact horizontal spacing
    }
    else
    {
        size.width = MAX(minSize.width, [([self stringValue] || @" ") sizeWithFont:[self font]].width + contentInset.left + contentInset.right);
    }
    return size;
}

- (void)layoutSubviews
{
    [super layoutSubviews];

    // Completely silence and transparentize the default text element natively
    if (self._DOMTextElement) {
        self._DOMTextElement.innerHTML = "";
        self._DOMTextElement.style.display = "none";
        self._DOMTextElement.style.visibility = "hidden";
        self._DOMTextElement.style.color = "transparent";
    }

    var rep = [self representedObject];
    if (rep && rep.code)
    {
        // Use raw CPViews instead of CPTextFields to completely bypass Cappuccino's
        // text drawing pipeline and prevent automatic font/color overrides.
        var codeLabel = [self viewWithTag:101];
        if (!codeLabel)
        {
            codeLabel = [[CPView alloc] initWithFrame:CGRectMakeZero()];
            [codeLabel setTag:101];
            [self addSubview:codeLabel];
        }

        var textLabel = [self viewWithTag:102];
        if (!textLabel)
        {
            textLabel = [[CPView alloc] initWithFrame:CGRectMakeZero()];
            [textLabel setTag:102];
            [self addSubview:textLabel];
        }

        // Render text and apply robust centering and sizing via pure CSS
        if (codeLabel._DOMElement)
        {
            codeLabel._DOMElement.innerHTML = rep.code;

            var codeStyle = codeLabel._DOMElement.style;
            codeStyle.backgroundColor = "rgb(0, 128, 180)";
            codeStyle.borderRadius = "3px";
            codeStyle.color = "white";
            codeStyle.lineHeight = "12px";
            codeStyle.textAlign = "center";
            codeStyle.fontSize = "8px";
            codeStyle.fontWeight = "bold";
            codeStyle.fontFamily = "sans-serif";
        }

        var displayText = rep.display || @"";
        if (displayText.length > 10) {
            displayText = [displayText substringToIndex:10] + @"...";
        }

        if (textLabel._DOMElement)
        {
            textLabel._DOMElement.innerHTML = displayText;

            var textStyle = textLabel._DOMElement.style;
            textStyle.color = "rgb(100, 100, 100)";
            textStyle.lineHeight = "12px";
            textStyle.textAlign = "center";
            textStyle.fontSize = "9px";
            textStyle.fontFamily = "sans-serif";
        }

        var bounds = [self bounds];
        var codeWidth = [rep.code sizeWithFont:[CPFont boldSystemFontOfSize:8.0]].width + 10;
        var textWidth = [displayText sizeWithFont:[CPFont systemFontOfSize:9.0]].width + 6;

        // Position badge and label inside the 18px high token (perfect vertical centering at y=3)
        [codeLabel setFrame:CGRectMake(4, 3, codeWidth, 12)];
        [textLabel setFrame:CGRectMake(codeWidth + 8, 3, textWidth, 12)];
    }
}

@end

// --------------------------------------------------------------------------------
// HPODragSourceView (Highly Visible, Dedicated Drag Station)
// --------------------------------------------------------------------------------

@implementation HPODragSourceView : CPView
{
    CPTextField _label;
    CPTextField _badge;
    id _representedTerm;
}

- (id)initWithFrame:(CGRect)aFrame
{
    self = [super initWithFrame:aFrame];
    if (self) {
        [self setBackgroundColor:[CPColor colorWithRed:0.96 green:0.98 blue:1.0 alpha:1.0]];

        // Apply dashed border styling
        self._DOMElement.style.border = "1.5px dashed #0080B4";
        self._DOMElement.style.borderRadius = "5px";
        self._DOMElement.style.cursor = "default";


        _badge = [[CPTextField alloc] initWithFrame:CGRectMake(2, 6, 80, 20)];
        [_badge setFont:[CPFont boldSystemFontOfSize:10.0]];
        [_badge setTextColor:[CPColor whiteColor]];
        [_badge setAlignment:CPCenterTextAlignment];
        [_badge setStringValue:@"HP:XXXXXXX"];
        _badge._DOMElement.style.backgroundColor = "#888888";
        _badge._DOMElement.style.borderRadius = "3px";
        _badge._DOMElement.style.lineHeight = "20px";
        [self addSubview:_badge];

        _label = [[CPTextField alloc] initWithFrame:CGRectMake(280, 8, aFrame.size.width - 290, 16)];
        [_label setFont:[CPFont systemFontOfSize:11.0]];
        [_label setTextColor:[CPColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:1.0]];
        [_label setStringValue:@"Select any HPO node below to begin dragging..."];
        [self addSubview:_label];
    }
    return self;
}

- (void)setTerm:(id)aTerm
{
    _representedTerm = aTerm;
    if (_representedTerm) {
        [_badge setStringValue:_representedTerm.code];
        [_label setStringValue:_representedTerm.display];
        [_label setTextColor:[CPColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:1.0]];
        _badge._DOMElement.style.backgroundColor = "#0080B4";
        self._DOMElement.style.backgroundColor = [CPColor colorWithRed:0.9 green:0.95 blue:1.0 alpha:1.0];
        self._DOMElement.style.border = "1.5px dashed #0080B4";
        self._DOMElement.style.cursor = "grab";
    } else {
        [_badge setStringValue:@"HP:XXXXXXX"];
        [_label setStringValue:@"Select any HPO node below to begin dragging..."];
        [_label setTextColor:[CPColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:1.0]];
        _badge._DOMElement.style.backgroundColor = "#888888";
        self._DOMElement.style.backgroundColor = [CPColor colorWithRed:0.96 green:0.98 blue:1.0 alpha:1.0];
        self._DOMElement.style.border = "1.5px dashed #cccccc";
        self._DOMElement.style.cursor = "default";
    }
}

- (id)term
{
    return _representedTerm;
}

- (void)mouseDragged:(CPEvent)anEvent
{
    if (!_representedTerm) return;

    var pboard = [CPPasteboard pasteboardWithName:CPDragPboard];
    [pboard declareTypes:[CPArray arrayWithObjects:@"HPOTermPboardType", CPStringPboardType, nil] owner:self];

    // Avoid raw object plist serialization errors by using a CPDictionary
    var dict = [CPDictionary dictionaryWithObjectsAndKeys:
                    _representedTerm.code, @"code",
                _representedTerm.display, @"display"
    ];

    [pboard setPropertyList:dict forType:@"HPOTermPboardType"];
    [pboard setString:_representedTerm.code forType:CPStringPboardType];

    // High contrast drag visual badge
    var dragView = [[CPView alloc] initWithFrame:CGRectMake(0, 0, 160, 24)];
    [dragView setBackgroundColor:[CPColor colorWithRed:0.0 green:0.5 blue:0.7 alpha:0.9]];
    dragView._DOMElement.style.borderRadius = "4px";

    var dragLabel = [[CPTextField alloc] initWithFrame:CGRectMake(8, 4, 144, 16)];
    [dragLabel setStringValue:_representedTerm.display];
    [dragLabel setTextColor:[CPColor whiteColor]];
    [dragLabel setFont:[CPFont boldSystemFontOfSize:10.0]];
    [dragView addSubview:dragLabel];

    [self dragView:dragView
                at:CGPointMakeZero()
            offset:CGSizeMakeZero()
             event:anEvent
        pasteboard:pboard
            source:self
         slideBack:YES];
}

@end

// --------------------------------------------------------------------------------
// HPOTokenField Subclass (With Native Drag-and-Drop Drop Target Implementation)
// --------------------------------------------------------------------------------

@implementation HPOTokenField : CPTokenField
{
    id _editorController;
}

- (void)setEditorController:(id)aController
{
    _editorController = aController;
}

- (CPDragOperation)draggingEntered:(id <CPDraggingInfo>)sender
{
    var pboard = [sender draggingPasteboard];
    if ([[pboard types] containsObject:@"HPOTermPboardType"] || [[pboard types] containsObject:CPStringPboardType])
    {
        return CPDragOperationCopy;
    }
    return CPDragOperationNone;
}

- (CPDragOperation)draggingUpdated:(id <CPDraggingInfo>)sender
{
    var pboard = [sender draggingPasteboard];
    if ([[pboard types] containsObject:@"HPOTermPboardType"] || [[pboard types] containsObject:CPStringPboardType])
    {
        return CPDragOperationCopy;
    }
    return CPDragOperationNone;
}

- (BOOL)performDragOperation:(id <CPDraggingInfo>)sender
{
    var pboard = [sender draggingPasteboard];
    var dict = nil;

    if ([[pboard types] containsObject:@"HPOTermPboardType"])
    {
        dict = [pboard propertyListForType:@"HPOTermPboardType"];
    }

    if (!dict && [[pboard types] containsObject:CPStringPboardType])
    {
        var str = [pboard stringForType:CPStringPboardType];
        if (str && [str hasPrefix:@"HP:"])
        {
            dict = { "code": str, "display": str };
        }
    }

    if (dict)
    {
        var code = nil;
        var display = nil;

        // Securely handle serialized CPDictionary properties as well as plain objects
        if ([dict respondsToSelector:@selector(objectForKey:)])
        {
            code = [dict objectForKey:@"code"];
            display = [dict objectForKey:@"display"];
        }
        else
        {
            code = dict.code;
            display = dict.display;
        }

        if (code)
        {
            var tokens = [self objectValue] || [];
            var exists = NO;
            for (var i = 0; i < tokens.length; i++)
            {
                var existingCode = tokens[i].code;
                if (existingCode === code)
                {
                    exists = YES;
                    break;
                }
            }
            if (!exists)
            {
                var mutableTokens = [CPMutableArray arrayWithArray:tokens];
                [mutableTokens addObject:{ "code": code, "display": display }];
                [self setObjectValue:mutableTokens];

                if (_editorController)
                {
                    [_editorController ruleEditorDidChange:self];
                }
            }
            return YES;
        }
    }
    return NO;
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
    CPString            _presenceMode;
    CPString            _combinationMethod @accessors(property=combinationMethod);
    int                 _indentation       @accessors(property=indentation);

    HPOTokenField       _tokenField        @accessors(property=tokenField);
    CPArray             _hpoTokens         @accessors(property=hpoTokens);
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
        _presenceMode = @"all-present";
        _combinationMethod = @"all-of";
        _indentation = 0;
        _hpoTokens = [];

        // Force initial population of standard inclusion metadata
        [self updateCriteriaAndDisplayValues];
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

- (void)setPresenceMode:(CPString)mode
{
    if (_presenceMode !== mode)
    {
        _presenceMode = mode;
        _exclude = [mode isEqualToString:@"neither-present"];
        [self updateCriteriaAndDisplayValues];
    }
}

- (CPString)presenceMode
{
    return _presenceMode;
}

- (void)setExclude:(BOOL)exclude
{
    if (_exclude !== exclude)
    {
        _exclude = exclude;
        _presenceMode = _exclude ? @"neither-present" : @"all-present";
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
                _presenceMode = second;
                _exclude = [second isEqualToString:@"neither-present"];
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
        if (!_presenceMode) {
            _presenceMode = _exclude ? @"neither-present" : @"all-present";
        }

        var dispPresence = @"All must be present";
        if (_presenceMode === @"any-present") {
            dispPresence = @"Any must be present";
        } else if (_presenceMode === @"neither-present") {
            dispPresence = @"Neither must be present";
        }

        [self setCriteria:[CPArray arrayWithObjects:@"phenotype", _presenceMode, @"_value_field_", nil]];
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
        if (criterion == @"phenotype") return 3; // "All", "Any", "Neither"
        if (criterion == @"all-present" || criterion == @"any-present" || criterion == @"neither-present") return 1; // token field input placeholder
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
        return (index == 0) ? @"all-present" : ((index == 1) ? @"any-present" : @"neither-present");

    if (criterion == @"all-present" || criterion == @"any-present" || criterion == @"neither-present")
        return @"_value_field_";

    return nil;
}

- (id)ruleEditor:(CPRuleEditor)editor displayValueForCriterion:(id)criterion inRow:(int)row
{
    if (criterion === CPAndPredicateType) return @"All";
    if (criterion === CPOrPredicateType) return @"Any";
    if (criterion === @"_logical_text_") return @"of the following are true";

    if (criterion == @"phenotype") return @"Symptom / Phenotype";
    if (criterion == @"all-present") return @"All must be present";
    if (criterion == @"any-present") return @"Any must be present";
    if (criterion == @"neither-present") return @"Neither must be present";

    if (criterion == @"_value_field_")
    {
        var node = [_controller nodeAtRowIndex:row];
        if (node)
        {
            var cachedField = [node tokenField];
            if (cachedField)
            {
                return cachedField;
            }

            var tokenField = [[HPOTokenField alloc] initWithFrame:CGRectMake(0, 0, 320, 24)];
            [tokenField setEditorController:_controller];
            [tokenField registerForDraggedTypes:[CPArray arrayWithObjects:@"HPOTermPboardType", nil]];

            [tokenField setEditable:YES];
            [tokenField setBezeled:YES];
            [tokenField setBackgroundColor:[CPColor whiteColor]];
            [tokenField setPlaceholderString:@"Drag and drop HPO codes here..."];

            [tokenField setDelegate:_controller];

            // Populate tokens
            var hpoTokens = [node hpoTokens] || [];
            [tokenField setObjectValue:hpoTokens];

            [tokenField setTarget:_controller];
            [tokenField setAction:@selector(ruleEditorDidChange:)];

            tokenField.node = node;

            [[CPNotificationCenter defaultCenter] addObserver:_controller
                                                     selector:@selector(ruleEditorDidChange:)
                                                         name:CPControlTextDidChangeNotification
                                                       object:tokenField];

            [node setTokenField:tokenField];
            return tokenField;
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
    else if (criterion === @"all-present" || criterion === @"any-present")
    {
        [result setObject:[CPNumber numberWithInt:CPEqualToPredicateOperatorType] forKey:CPRuleEditorPredicateOperatorType];
        [result setObject:[CPNumber numberWithInt:CPDirectPredicateModifier] forKey:CPRuleEditorPredicateComparisonModifier];
        [result setObject:[CPNumber numberWithInt:CPCaseInsensitivePredicateOption] forKey:CPRuleEditorPredicateOptions];
    }
    else if (criterion === @"neither-present")
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

    // Workspace Pane
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

    // Embedded HPO Tree Browser (Positioned below the Rule Editor)
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

    HPODragSourceView    _dragSourcePanel;

    CPArray              _allRoots;
    CPArray              _synonyms;
    CPArray              _xrefs;
    CPArray              _downstreamTerms;
    CPArray              _matchedIndexPaths;
    int                  _currentMatchIndex;

    // Phenopacket Extractor UI elements
    CPTextView           _reportInputTextView;
    CPTextView           _phenopacketOutputTextView;
    CPButton             _extractPhenoButton;
    CPButton             _extractICD10Button;
    CPTextField          _extractStatusLabel;

    CPButton             _matchButton;
    CPTextField          _matchStatusLabel;
    CPTableView          _crossmatchTableView;
    CPArray              _crossmatchResults;
}

- (void)applicationDidFinishLaunching:(CPNotification)aNotification
{
    var theWindow = [[CPWindow alloc] initWithContentRect:CGRectMake(0, 0, 1100, 850) styleMask:CPBorderlessBridgeWindowMask];
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

    [self _buildIntegratedWorkspace];

    [theWindow orderFront:self];
    [self fetchRoots];
}

// --------------------------------------------------------------------------------
// CPTokenFieldDelegate Implementations (Converting strings to rich tokens)
// --------------------------------------------------------------------------------

- (CPString)tokenField:(CPTokenField)tokenField displayStringForRepresentedObject:(id)representedObject
{
    return "";
}

- (id)tokenField:(CPTokenField)tokenField representedObjectForEditingString:(CPString)editingString
{
    var cleanString = [editingString stringByTrimmingCharactersInSet:[CPCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([cleanString hasPrefix:@"HP:"])
    {
        var parts = [cleanString componentsSeparatedByString:@" "];
        var code = parts[0];
        [parts removeObjectAtIndex:0];
        var display = [parts componentsJoinedByString:@" "] || @"Manual Entry";
        return { "code": code, "display": display };
    }
    return { "code": @"HP:0000118", "display": cleanString };
}

- (CPArray)tokenField:(CPTokenField)tokenField completionsForSubstring:(CPString)substring indexOfToken:(CPInteger)tokenIndex indexOfSelectedItem:(CPInteger)selectedIndex
{
    return [];
}

// --------------------------------------------------------------------------------
// Native Drag Source implementation for HPO Hierarchy elements
// --------------------------------------------------------------------------------

- (BOOL)outlineView:(CPOutlineView)anOutlineView writeItems:(CPArray)items toPasteboard:(CPPasteboard)pboard
{
    if ([items count] === 0) return NO;
    var treeNode = [items objectAtIndex:0];
    var node = [treeNode representedObject];
    if (!node || [node name] === @"Loading...") return NO;

    var termId = [node termId];
    var formattedId = "HP:" + [CPString stringWithFormat:"%07d", termId + 0];

    // Package securely as CPDictionary to stop deserializer exceptions
    var dict = [CPDictionary dictionaryWithObjectsAndKeys:
                    formattedId, @"code",
                [node name], @"display"
    ];

    [pboard declareTypes:[CPArray arrayWithObjects:@"HPOTermPboardType", CPStringPboardType, nil] owner:self];
    [pboard setPropertyList:dict forType:@"HPOTermPboardType"];
    [pboard setString:formattedId forType:CPStringPboardType];
    return YES;
}

- (BOOL)tableView:(CPTableView)aTableView writeRowsWithIndexes:(CPIndexSet)rowIndexes toPasteboard:(CPPasteboard)pboard
{
    if (aTableView === downstreamTableView)
    {
        var clickedRow = [rowIndexes firstIndex];
        if (clickedRow === CPNotFound || clickedRow >= [_downstreamTerms count]) return NO;

        var term = _downstreamTerms[clickedRow];
        var formattedId = "HP:" + [CPString stringWithFormat:"%07d", term.id + 0];

        // Package securely as CPDictionary to stop deserializer exceptions
        var dict = [CPDictionary dictionaryWithObjectsAndKeys:
                        formattedId, @"code",
                    term.label, @"display"
        ];

        [pboard declareTypes:[CPArray arrayWithObjects:@"HPOTermPboardType", CPStringPboardType, nil] owner:self];
        [pboard setPropertyList:dict forType:@"HPOTermPboardType"];
        [pboard setString:formattedId forType:CPStringPboardType];
        return YES;
    }
    return NO;
}

// --------------------------------------------------------------------------------
// Integrated Unified Workspace Layout Builder
// --------------------------------------------------------------------------------

- (void)_buildIntegratedWorkspace
{
    var tabViewBounds = [_tabView bounds];

    // ==========================================
    // TAB 1: Clinical Eligibility & HPO Workspace
    // ==========================================
    var mainTab = [[CPTabViewItem alloc] initWithIdentifier:@"workspaceTab"];
    [mainTab setLabel:@"Clinical Eligibility & HPO Workspace"];

    var mainView = [[CPView alloc] initWithFrame:tabViewBounds];
    [mainTab setView:mainView];
    [_tabView addTabViewItem:mainTab];

    var mainSplitView = [[CPSplitView alloc] initWithFrame:[mainView bounds]];
    [mainSplitView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [mainSplitView setVertical:YES];

    [mainView addSubview:mainSplitView];

    var leftWidth = CGRectGetWidth([mainView bounds]) * 0.35;
    var rightWidth = CGRectGetWidth([mainView bounds]) - leftWidth - [mainSplitView dividerThickness];

    // Left Column: Clinical protocol synopsis panel
    var leftContainer = [[CPView alloc] initWithFrame:CGRectMake(0, 0, leftWidth, CGRectGetHeight([mainView bounds]))];
    [leftContainer setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];

    var synopsisBox = [[CPBox alloc] initWithFrame:CGRectMake(10, 10, leftWidth - 20, CGRectGetHeight([mainView bounds]) - 160)];
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

    var settingsBox = [[CPBox alloc] initWithFrame:CGRectMake(10, CGRectGetHeight([mainView bounds]) - 145, leftWidth - 20, 105)];
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

    // Right Column: Split layout (Rule Editor at the top, HPO Hierarchy Browser below)
    var rightContainer = [[CPView alloc] initWithFrame:CGRectMake(0, 0, rightWidth, CGRectGetHeight([mainView bounds]))];
    [rightContainer setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];

    var rightSplitView = [[CPSplitView alloc] initWithFrame:[rightContainer bounds]];
    [rightSplitView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [rightSplitView setVertical:NO]; // Split horizontally, creating top and bottom halves

    var initialTopHeight = CGRectGetHeight([rightContainer bounds]) * 0.42;

    // Right Top: Rule Editor
    var topPane = [[CPView alloc] initWithFrame:CGRectMake(0, 0, rightWidth, initialTopHeight)];
    [topPane setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];

    var ruleBox = [[CPBox alloc] initWithFrame:CGRectMake(10, 10, rightWidth - 20, initialTopHeight - 55)];
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
    [topPane addSubview:ruleBox];

    var btnY = initialTopHeight - 38;
    _addRuleBtn = [[CPButton alloc] initWithFrame:CGRectMake(15, btnY, 110, 24)];
    [_addRuleBtn setTitle:@"Add Criterion"];
    [_addRuleBtn setTarget:self];
    [_addRuleBtn setAction:@selector(addSimpleRule:)];
    [_addRuleBtn setAutoresizingMask:CPViewMinYMargin];
    [topPane addSubview:_addRuleBtn];

    _addGroupBtn = [[CPButton alloc] initWithFrame:CGRectMake(135, btnY, 110, 24)];
    [_addGroupBtn setTitle:@"Add Group"];
    [_addGroupBtn setTarget:self];
    [_addGroupBtn setAction:@selector(addGroupRule:)];
    [_addGroupBtn setAutoresizingMask:CPViewMinYMargin];
    [topPane addSubview:_addGroupBtn];

    _clearBtn = [[CPButton alloc] initWithFrame:CGRectMake(255, btnY, 80, 24)];
    [_clearBtn setTitle:@"Reset"];
    [_clearBtn setTarget:self];
    [_clearBtn setAction:@selector(resetEditor:)];
    [_clearBtn setAutoresizingMask:CPViewMinYMargin];
    [topPane addSubview:_clearBtn];

    _showJsonBtn = [[CPButton alloc] initWithFrame:CGRectMake(rightWidth - 195, btnY, 180, 24)];
    [_showJsonBtn setTitle:@"View FHIR R6 JSON"];
    [_showJsonBtn setTarget:self];
    [_showJsonBtn setAction:@selector(showJSONPopover:)];
    [_showJsonBtn setAutoresizingMask:CPViewMinYMargin | CPViewMinXMargin];
    [topPane addSubview:_showJsonBtn];

    // Right Bottom: Integrated HPO Hierarchy Browser
    var initialBottomHeight = CGRectGetHeight([rightContainer bounds]) - initialTopHeight - [rightSplitView dividerThickness];
    var bottomPane = [[CPView alloc] initWithFrame:CGRectMake(0, 0, rightWidth, initialBottomHeight)];
    [bottomPane setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];

    var browserBox = [[CPBox alloc] initWithFrame:CGRectMake(10, 10, rightWidth - 20, initialBottomHeight - 20)];
    [browserBox setTitle:@"HPO Term Browser"];
    [browserBox setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [bottomPane addSubview:browserBox];

    var bBoxBounds = [[browserBox contentView] bounds];

    // Search header inside the browser box
    _searchField = [[CPSearchField alloc] initWithFrame:CGRectMake(10, 10, CGRectGetWidth(bBoxBounds) - 340, 26)];
    [_searchField setAutoresizingMask:CPViewWidthSizable | CPViewMaxYMargin];
    [_searchField setPlaceholderString:@"Search terms, synonyms, descriptions..."];
    [_searchField setTarget:self];
    [_searchField setAction:@selector(searchAction:)];
    [[browserBox contentView] addSubview:_searchField];

    _searchStatusLabel = [[CPTextField alloc] initWithFrame:CGRectMake(CGRectGetWidth(bBoxBounds) - 325, 13, 60, 20)];
    [_searchStatusLabel setStringValue:@""];
    [_searchStatusLabel setAutoresizingMask:CPViewMinXMargin | CPViewMaxYMargin];
    [_searchStatusLabel setAlignment:CPRightTextAlignment];
    [[browserBox contentView] addSubview:_searchStatusLabel];

    var prevBtn = [[CPButton alloc] initWithFrame:CGRectMake(CGRectGetWidth(bBoxBounds) - 255, 11, 28, 24)];
    [prevBtn setTitle:@"<"];
    [prevBtn setAutoresizingMask:CPViewMinXMargin | CPViewMaxYMargin];
    [prevBtn setTarget:self];
    [prevBtn setAction:@selector(prevMatch:)];
    [[browserBox contentView] addSubview:prevBtn];

    var nextBtn = [[CPButton alloc] initWithFrame:CGRectMake(CGRectGetWidth(bBoxBounds) - 222, 11, 28, 24)];
    [nextBtn setTitle:@">"];
    [nextBtn setAutoresizingMask:CPViewMinXMargin | CPViewMaxYMargin];
    [nextBtn setTarget:self];
    [nextBtn setAction:@selector(nextMatch:)];
    [[browserBox contentView] addSubview:nextBtn];

    _nameOnlyCheckbox = [[CPCheckBox alloc] initWithFrame:CGRectMake(CGRectGetWidth(bBoxBounds) - 185, 13, 100, 20)];
    [_nameOnlyCheckbox setTitle:@"Name only"];
    [_nameOnlyCheckbox setAutoresizingMask:CPViewMinXMargin | CPViewMaxYMargin];
    [_nameOnlyCheckbox setState:CPOffState];
    [[browserBox contentView] addSubview:_nameOnlyCheckbox];

    // Drag-Source Panel (Fits right below search bar at y=45)
    _dragSourcePanel = [[HPODragSourceView alloc] initWithFrame:CGRectMake(10, 42, CGRectGetWidth(bBoxBounds) - 20, 32)];
    [_dragSourcePanel setAutoresizingMask:CPViewWidthSizable | CPViewMaxYMargin];
    [[browserBox contentView] addSubview:_dragSourcePanel];

    // Inner Split: Left (Tree Structure) / Right (Analytical details)
    var hpoInnerSplit = [[CPSplitView alloc] initWithFrame:CGRectMake(10, 80, CGRectGetWidth(bBoxBounds) - 20, CGRectGetHeight(bBoxBounds) - 90)];
    [hpoInnerSplit setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [hpoInnerSplit setVertical:YES];
    [[browserBox contentView] addSubview:hpoInnerSplit];

    var innerWidth = CGRectGetWidth([hpoInnerSplit bounds]);
    var innerHeight = CGRectGetHeight([hpoInnerSplit bounds]);
    var innerDividerWidth = [hpoInnerSplit dividerThickness];

    var treeWidth = (innerWidth - innerDividerWidth) * 0.45;
    var detailsWidth = (innerWidth - innerDividerWidth) - treeWidth;

    // Initialize the Tree Controller
    treeController = [[CPTreeController alloc] init];
    [treeController setChildrenKeyPath:@"children"];
    [treeController setLeafKeyPath:@"isLeaf"];

    // HPO Left: Main Outline Tree View
    var treeScroll = [[CPScrollView alloc] initWithFrame:CGRectMake(0, 0, treeWidth, innerHeight)];
    [treeScroll setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [treeScroll setAutohidesScrollers:NO];

    outlineView = [[HPOOutlineView alloc] initWithFrame:[treeScroll bounds]];
    var column = [[CPTableColumn alloc] initWithIdentifier:@"name"];
    [[column headerView] setStringValue:@"HPO Tree Nodes"];
    [column setResizingMask:CPTableColumnAutoresizingMask];
    [outlineView setColumnAutoresizingStyle:CPTableViewLastColumnOnlyAutoresizingStyle];
    [outlineView addTableColumn:column];
    [outlineView setOutlineTableColumn:column];
    [outlineView setAllowsMultipleSelection:NO];
    [outlineView setDelegate:self];
    [treeScroll setDocumentView:outlineView];
    [hpoInnerSplit addSubview:treeScroll];

    // HPO Right: Analytical Details Tab View (Conserves workspace space dynamically)
    var detailsContainer = [[CPView alloc] initWithFrame:CGRectMake(0, 0, detailsWidth, innerHeight)];
    [detailsContainer setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];

    var hpoDetailsTab = [[CPTabView alloc] initWithFrame:[detailsContainer bounds]];
    [hpoDetailsTab setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [detailsContainer addSubview:hpoDetailsTab];

    // Tab 1: Term Definition & Associated Synonyms
    var defTabItem = [[CPTabViewItem alloc] initWithIdentifier:@"defItem"];
    [defTabItem setLabel:@"Definition & Synonyms"];
    var defTabInner = [[CPView alloc] initWithFrame:[hpoDetailsTab bounds]];
    [defTabItem setView:defTabInner];
    [hpoDetailsTab addTabViewItem:defTabItem];

    var tabHeight = CGRectGetHeight([hpoDetailsTab bounds]);
    var defScrollHeight = tabHeight * 0.35;
    var synScrollHeight = tabHeight - defScrollHeight - 35;

    var defScroll = [[CPScrollView alloc] initWithFrame:CGRectMake(5, 5, detailsWidth - 10, defScrollHeight)];
    [defScroll setAutoresizingMask:CPViewWidthSizable];
    [defScroll setAutohidesScrollers:YES];
    [defScroll setHasHorizontalScroller:NO];

    definitionTextView = [[CPTextView alloc] initWithFrame:[defScroll bounds]];
    [definitionTextView setAutoresizingMask:CPViewWidthSizable];
    [definitionTextView setEditable:NO];
    [definitionTextView setSelectable:YES];
    [defScroll setDocumentView:definitionTextView];
    [defTabInner addSubview:defScroll];

    var synScroll = [[CPScrollView alloc] initWithFrame:CGRectMake(5, defScrollHeight + 10, detailsWidth - 10, synScrollHeight)];
    [synScroll setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [synScroll setAutohidesScrollers:YES];

    synonymsTableView = [[CPTableView alloc] initWithFrame:[synScroll bounds]];
    var synCol = [[CPTableColumn alloc] initWithIdentifier:@"label"];
    [[synCol headerView] setStringValue:@"Associated Synonyms"];
    [synCol setSortDescriptorPrototype:[CPSortDescriptor sortDescriptorWithKey:@"label" ascending:YES]];
    [synCol setWidth:detailsWidth - 30];
    [synonymsTableView addTableColumn:synCol];
    [synonymsTableView setDataSource:self];
    [synScroll setDocumentView:synonymsTableView];
    [defTabInner addSubview:synScroll];

    // Tab 2: Database Mapping Cross References (Xrefs)
    var xrefTabItem = [[CPTabViewItem alloc] initWithIdentifier:@"xrefItem"];
    [xrefTabItem setLabel:@"Cross References"];
    var xrefTabInner = [[CPView alloc] initWithFrame:[hpoDetailsTab bounds]];
    [xrefTabItem setView:xrefTabInner];
    [hpoDetailsTab addTabViewItem:xrefTabItem];

    var xrefScroll = [[CPScrollView alloc] initWithFrame:CGRectMake(5, 5, detailsWidth - 10, tabHeight - 40)];
    [xrefScroll setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [xrefScroll setAutohidesScrollers:YES];

    xrefsTableView = [[CPTableView alloc] initWithFrame:[xrefScroll bounds]];
    var xrefCol = [[CPTableColumn alloc] initWithIdentifier:@"xref"];
    [xrefCol setSortDescriptorPrototype:[CPSortDescriptor sortDescriptorWithKey:@"xref" ascending:YES]];
    [[xrefCol headerView] setStringValue:@"Database Mapping references"];
    [xrefCol setWidth:detailsWidth - 30];
    [xrefsTableView addTableColumn:xrefCol];
    [xrefsTableView setDataSource:self];
    [xrefScroll setDocumentView:xrefsTableView];
    [xrefTabInner addSubview:xrefScroll];

    // Tab 3: Downstream Child Classes
    var downTabItem = [[CPTabViewItem alloc] initWithIdentifier:@"downItem"];
    [downTabItem setLabel:@"Downstream Classes"];
    var downTabInner = [[CPView alloc] initWithFrame:[hpoDetailsTab bounds]];
    [downTabItem setView:downTabInner];
    [hpoDetailsTab addTabViewItem:downTabItem];

    var downScroll = [[CPScrollView alloc] initWithFrame:CGRectMake(5, 5, detailsWidth - 10, tabHeight - 75)];
    [downScroll setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [downScroll setAutohidesScrollers:YES];

    downstreamTableView = [[CPTableView alloc] initWithFrame:[downScroll bounds]];
    [downstreamTableView setTarget:self];
    [downstreamTableView setDoubleAction:@selector(doubleClickDownstream:)];
    [downstreamTableView setDataSource:self]; // Drag source permitted for downstream children

    var downIdCol = [[CPTableColumn alloc] initWithIdentifier:@"id"];
    [[downIdCol headerView] setStringValue:@"Class ID"];
    [downIdCol setSortDescriptorPrototype:[CPSortDescriptor sortDescriptorWithKey:@"id" ascending:YES]];
    [downIdCol setWidth:90];
    [downstreamTableView addTableColumn:downIdCol];

    var downLabelCol = [[CPTableColumn alloc] initWithIdentifier:@"label"];
    [[downLabelCol headerView] setStringValue:@"Ontology Standard Label"];
    [downLabelCol setSortDescriptorPrototype:[CPSortDescriptor sortDescriptorWithKey:@"label" ascending:YES]];
    [downLabelCol setWidth:detailsWidth - 130];
    [downstreamTableView addTableColumn:downLabelCol];
    [downScroll setDocumentView:downstreamTableView];
    [downTabInner addSubview:downScroll];

    var exportBtn = [[CPButton alloc] initWithFrame:CGRectMake(5, tabHeight - 65, 140, 24)];
    [exportBtn setAutoresizingMask:CPViewMinYMargin | CPViewMaxXMargin];
    [exportBtn setTitle:@"Export Tree IDs"];
    [exportBtn setTarget:self];
    [exportBtn setAction:@selector(exportDownstream:)];
    [downTabInner addSubview:exportBtn];

    [hpoInnerSplit addSubview:detailsContainer];

    [rightSplitView addSubview:topPane];
    [rightSplitView addSubview:bottomPane];

    [rightContainer addSubview:rightSplitView];

    [mainSplitView addSubview:leftContainer];
    [mainSplitView addSubview:rightContainer];


    // ==========================================
    // TAB 2: Phenopacket / ICD Extractor
    // ==========================================
    var phenoTab = [[CPTabViewItem alloc] initWithIdentifier:@"phenoTab"];
    [phenoTab setLabel:@"Phenopacket / ICD Extractor"];
    var phenoView = [[CPView alloc] initWithFrame:tabViewBounds];
    [phenoTab setView:phenoView];
    [_tabView addTabViewItem:phenoTab];

    var extractorSplitHeight = CGRectGetHeight(tabViewBounds) - 90;
    var extractorSplit = [[CPSplitView alloc] initWithFrame:CGRectMake(20, 20, CGRectGetWidth(tabViewBounds) - 40, extractorSplitHeight)];
    [extractorSplit setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [extractorSplit setVertical:YES]; // Left/Right panes

    var extractorWidth = CGRectGetWidth([extractorSplit bounds]);
    var extractorDivider = [extractorSplit dividerThickness];
    var halfWidth = (extractorWidth - extractorDivider) / 2;

    // --- Extractor Left: Input ---
    var inputBox = [[CPBox alloc] initWithFrame:CGRectMake(0, 0, halfWidth, extractorSplitHeight)];
    [inputBox setTitle:@"Narrative Medical Report"];
    [inputBox setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];

    var inputScroll2 = [[CPScrollView alloc] initWithFrame:[[inputBox contentView] bounds]];
    [inputScroll2 setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [inputScroll2 setAutohidesScrollers:YES];

    _reportInputTextView = [[CPTextView alloc] initWithFrame:[inputScroll2 bounds]];
    [_reportInputTextView setAutoresizingMask:CPViewWidthSizable];
    [inputScroll2 setDocumentView:_reportInputTextView];

    [[inputBox contentView] addSubview:inputScroll2];
    [extractorSplit addSubview:inputBox];

    // --- Extractor Right: Output ---
    var outputBox = [[CPBox alloc] initWithFrame:CGRectMake(0, 0, halfWidth, extractorSplitHeight)];
    [outputBox setTitle:@"Extracted Phenopacket (JSON)"];
    [outputBox setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];

    var outputScroll2 = [[CPScrollView alloc] initWithFrame:[[outputBox contentView] bounds]];
    [outputScroll2 setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [outputScroll2 setAutohidesScrollers:YES];

    _phenopacketOutputTextView = [[CPTextView alloc] initWithFrame:[outputScroll2 bounds]];
    [_phenopacketOutputTextView setAutoresizingMask:CPViewWidthSizable];
    [_phenopacketOutputTextView setEditable:NO];
    [_phenopacketOutputTextView setSelectable:YES];
    [outputScroll2 setDocumentView:_phenopacketOutputTextView];

    [[outputBox contentView] addSubview:outputScroll2];
    [extractorSplit addSubview:outputBox];

    [phenoView addSubview:extractorSplit];

    // --- Extract Buttons ---
    _extractPhenoButton = [[CPButton alloc] initWithFrame:CGRectMake(20, CGRectGetMaxY([extractorSplit frame]) + 15, 180, 30)];
    [_extractPhenoButton setTitle:@"Extract phenopacket"];
    [_extractPhenoButton setAutoresizingMask:CPViewMinYMargin | CPViewMaxXMargin];
    [_extractPhenoButton setTarget:self];
    [_extractPhenoButton setAction:@selector(extractPhenopacketAction:)];
    [phenoView addSubview:_extractPhenoButton];

    _extractICD10Button = [[CPButton alloc] initWithFrame:CGRectMake(210, CGRectGetMaxY([extractorSplit frame]) + 15, 150, 30)];
    [_extractICD10Button setTitle:@"Extract ICD-10"];
    [_extractICD10Button setAutoresizingMask:CPViewMinYMargin | CPViewMaxXMargin];
    [_extractICD10Button setTarget:self];
    [_extractICD10Button setAction:@selector(extractICD10Action:)];
    [phenoView addSubview:_extractICD10Button];

    // Status Label
    _extractStatusLabel = [[CPTextField alloc] initWithFrame:CGRectMake(CGRectGetMaxX([_extractICD10Button frame]) + 20, CGRectGetMinY([_extractPhenoButton frame]) + 5 , 200, 20)];
    [_extractStatusLabel setStringValue:@""];
    [_extractStatusLabel setAutoresizingMask:CPViewMaxXMargin | CPViewMinYMargin];
    [_extractStatusLabel setAlignment:CPLeftTextAlignment];
    [phenoView addSubview:_extractStatusLabel];

    // ==========================================
    // TAB 3: Crossmatch results
    // ==========================================
    var crossmatchTab = [[CPTabViewItem alloc] initWithIdentifier:@"crossmatchTab"];
    [crossmatchTab setLabel:@"Crossmatch results"];
    var crossmatchView = [[CPView alloc] initWithFrame:tabViewBounds];
    [crossmatchTab setView:crossmatchView];
    [_tabView addTabViewItem:crossmatchTab];

    _crossmatchResults = [];

    // Oben: Panel für Match-Aktion und Statusanzeige
    var matchPanel = [[CPView alloc] initWithFrame:CGRectMake(20, 20, tabViewBounds.size.width - 40, 50)];
    [matchPanel setAutoresizingMask:CPViewWidthSizable | CPViewMaxYMargin];
    [crossmatchView addSubview:matchPanel];

    _matchButton = [[CPButton alloc] initWithFrame:CGRectMake(0, 10, 180, 30)];
    [_matchButton setTitle:@"Run Patient Matching"];
    [_matchButton setTarget:self];
    [_matchButton setAction:@selector(runPatientMatchingAction:)];
    [matchPanel addSubview:_matchButton];

    _matchStatusLabel = [[CPTextField alloc] initWithFrame:CGRectMake(200, 15, tabViewBounds.size.width - 260, 20)];
    [_matchStatusLabel setFont:[CPFont boldSystemFontOfSize:13.0]];
    [_matchStatusLabel setStringValue:@"Ready to crossmatch. Please compile/extract study criteria and a phenopacket first."];
    [_matchStatusLabel setTextColor:[CPColor grayColor]];
    [_matchStatusLabel setAutoresizingMask:CPViewWidthSizable];
    [matchPanel addSubview:_matchStatusLabel];

    // Darunter: CPTableView für Phänotypen
    var tableScroll = [[CPScrollView alloc] initWithFrame:CGRectMake(20, 80, tabViewBounds.size.width - 40, tabViewBounds.size.height - 150)];
    [tableScroll setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [tableScroll setAutohidesScrollers:YES];
    [tableScroll setBorderType:CPBezelBorder];
    [crossmatchView addSubview:tableScroll];

    _crossmatchTableView = [[CPTableView alloc] initWithFrame:[tableScroll bounds]];
    [_crossmatchTableView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [_crossmatchTableView setRowHeight:26.0];
    [_crossmatchTableView setDataSource:self];
    [_crossmatchTableView setDelegate:self];

    // Spalte 1: Match Status (Farbiger Kreis-Indikator)
    var statusCol = [[CPTableColumn alloc] initWithIdentifier:@"status"];
    [[statusCol headerView] setStringValue:@"Match Status"];
    [statusCol setWidth:130];
    [_crossmatchTableView addTableColumn:statusCol];

    // Spalte 2: Patient HPO Code
    var patientHpoCol = [[CPTableColumn alloc] initWithIdentifier:@"patient_hpo"];
    [[patientHpoCol headerView] setStringValue:@"Patient HPO"];
    [patientHpoCol setWidth:110];
    [_crossmatchTableView addTableColumn:patientHpoCol];

    // Spalte 3: Patient Phänotyp Bezeichnung
    var patientLabelCol = [[CPTableColumn alloc] initWithIdentifier:@"patient_label"];
    [[patientLabelCol headerView] setStringValue:@"Patient Phenotype Label"];
    [patientLabelCol setWidth:240];
    [_crossmatchTableView addTableColumn:patientLabelCol];

    // Spalte 4: Matched Study Criterion
    var matchedCriterionCol = [[CPTableColumn alloc] initWithIdentifier:@"matched_criterion"];
    [[matchedCriterionCol headerView] setStringValue:@"Matched Study Criterion"];
    [matchedCriterionCol setWidth:280];
    [_crossmatchTableView addTableColumn:matchedCriterionCol];

    [tableScroll setDocumentView:_crossmatchTableView];

    // Finish building layout
    [self resetEditor:self];

    [outlineView bind:@"content" toObject:treeController withKeyPath:@"arrangedObjects" options:nil];
    [outlineView bind:@"selectionIndexPaths" toObject:treeController withKeyPath:@"selectionIndexPaths" options:nil];

    [[CPNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ruleEditorDidChange:)
                                                 name:CPRuleEditorRowsDidChangeNotification
                                               object:_ruleEditor];
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

            var tokens = [];
            var rawLabels = sym.labels || (sym.label ? [sym.label] : []);
            for (var k = 0; k < rawLabels.length; k++) {
                tokens.push({
                    "system": "http://human-phenotype-ontology.org",
                    "code": "",
                    "display": rawLabels[k]
                });
            }

            var fhirChar = {
                "exclude": sym.exclude ? true : false,
                "combinationMethod": fhirCharacteristics.length > 0 ? (sym.combinationMethod || "all-of") : (sym.exclude ? "neither-of" : "all-of"),
                "valueCodeableConcept": {
                    "coding": tokens
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
    return node ? [node tokenField] : nil;
}

// --------------------------------------------------------------------------------
// Unified Workspace Insertion Methods
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

    if ([control isKindOfClass:[HPOTokenField class]] && control.node)
    {
        var tokens = [control objectValue] || [];
        [control.node setHpoTokens:tokens];
        if (tokens.length > 0)
        {
            [control.node setSymptomText:tokens[0].display];
        }
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

// --------------------------------------------------------------------------------
// Phenopacket & ICD-10 Extractor Actions
// --------------------------------------------------------------------------------

- (void)extractPhenopacketAction:(id)sender
{
    var narrativeText = [_reportInputTextView string];

    if (!narrativeText || [narrativeText length] === 0) {
        [_phenopacketOutputTextView setString:@"Please paste a medical report on the left before extracting."];
        return;
    }

    var selectedModel = [_modelPopUpButton titleOfSelectedItem];

    [_extractPhenoButton setEnabled:NO];
    [_extractPhenoButton setTitle:@"Extracting..."];
    [_phenopacketOutputTextView setString:@"Extracting phenopacket, please wait..."];

    [_extractStatusLabel setStringValue:@"Extracting..."];
    [self startExtractPulsatingAnimation];

    var request = [CPURLRequest requestWithURL:"/DBB/extract_phenopacket"];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    var payload = { "report": narrativeText, "model": selectedModel };
    var postData = [CPString stringWithString:JSON.stringify(payload)];
    [request setHTTPBody:postData];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
     {
        [_extractPhenoButton setEnabled:YES];
        [_extractPhenoButton setTitle:@"Extract phenopacket"];
        [self stopExtractPulsatingAnimation];
        [_extractStatusLabel setStringValue:@""];

        if (!error && data) {
            try {
                var parsedData = JSON.parse(data);
                var prettyJSON = JSON.stringify(parsedData, null, 4);
                [_phenopacketOutputTextView setString:prettyJSON];
            } catch (e) {
                [_phenopacketOutputTextView setString:data];
            }
        } else {
            var errorMsg = (error) ? [error localizedDescription] : @"Unknown error occurred.";
            [_phenopacketOutputTextView setString:@"Failed to extract phenopacket:\n\n" + errorMsg];
            console.log("Extraction Error: ", error);
        }
    }];
}

- (void)extractICD10Action:(id)sender
{
    var narrativeText = [_reportInputTextView string];

    if (!narrativeText || [narrativeText length] === 0) {
        [_phenopacketOutputTextView setString:@"Please paste a medical report on the left before extracting."];
        return;
    }

    var selectedModel = [_modelPopUpButton titleOfSelectedItem];

    [_extractICD10Button setEnabled:NO];
    [_extractICD10Button setTitle:@"Extracting..."];
    [_phenopacketOutputTextView setString:@"Extracting ICD-10 codes, please wait..."];

    [_extractStatusLabel setStringValue:@"Extracting..."];
    [self startExtractPulsatingAnimation];

    var request = [CPURLRequest requestWithURL:"/DBB/extract_icd10"];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    var payload = { "report": narrativeText, "model": selectedModel };
    var postData = [CPString stringWithString:JSON.stringify(payload)];
    [request setHTTPBody:postData];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
     {
        [_extractICD10Button setEnabled:YES];
        [_extractICD10Button setTitle:@"Extract ICD-10"];
        [self stopExtractPulsatingAnimation];
        [_extractStatusLabel setStringValue:@""];

        if (!error && data) {
            try {
                var parsedData = JSON.parse(data);
                var prettyJSON = JSON.stringify(parsedData, null, 4);
                [_phenopacketOutputTextView setString:prettyJSON];
            } catch (e) {
                [_phenopacketOutputTextView setString:data];
            }
        } else {
            var errorMsg = (error) ? [error localizedDescription] : @"Unknown error occurred.";
            [_phenopacketOutputTextView setString:@"Failed to extract ICD-10:\n\n" + errorMsg];
            console.log("Extraction Error: ", error);
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
            "combinationMethod": feat.exclude ? "neither-of" : "all-of",
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

// Resolves references within the contained resources recursively, preparing subgroups inline
- (id)resolveContainedReferencesInGroup:(id)rootGroup
{
    if (!rootGroup) return nil;
    var contained = rootGroup.contained || [];
    var containedMap = {};
    for (var i = 0; i < contained.length; i++) {
        var c = contained[i];
        if (c.id) {
            containedMap["#" + c.id] = c;
        }
    }
    return [self resolveReferencesInItem:rootGroup withMap:containedMap];
}

- (id)resolveReferencesInItem:(id)item withMap:(id)containedMap
{
    if (!item || typeof item !== 'object') return item;

    if (item.valueReference && item.valueReference.reference) {
        var ref = item.valueReference.reference;
        var referenced = containedMap[ref];
        if (referenced) {
            var resolved = JSON.parse(JSON.stringify(referenced));
            resolved.exclude = item.exclude ? true : false; // Propagate parent's exclusion flag down
            return resolved;
        }
    }

    if (Array.isArray(item)) {
        var arr = [];
        for (var i = 0; i < item.length; i++) {
            arr.push([self resolveReferencesInItem:item[i] withMap:containedMap]);
        }
        return arr;
    }

    var keys = Object.keys(item);
    var result = {};
    for (var i = 0; i < keys.length; i++) {
        var k = keys[i];
        result[k] = [self resolveReferencesInItem:item[k] withMap:containedMap];
    }
    return result;
}

// Rebuilds deep composite subgroups and single characteristics recursively into FHIRCriteriaNodes
- (FHIRCriteriaNode)nodeFromFHIRGroup:(id)group
{
    if (!group) return nil;

    var node = [[FHIRCriteriaNode alloc] init];

    var isCompound = NO;
    var combMethod = group.combinationMethod || "all-of";
    var characteristics = group.characteristic || [];

    if (characteristics.length > 0 || group.resourceType === "Group")
    {
        isCompound = YES;
    }

    if (isCompound)
    {
        [node setRowType:CPRuleEditorRowTypeCompound];
        [node setCombinationMethod:combMethod];
        [node updateCriteriaAndDisplayValues];

        var subrows = [CPMutableArray array];
        for (var i = 0; i < characteristics.length; i++)
        {
            var charItem = characteristics[i];
            var isCompositeSubgroup = NO;
            var isSubgroup = (charItem.resourceType === "Group" || charItem.characteristic || charItem.combinationMethod);

            // Check for composite grouping: either via ID prefix or structural content analysis
            if (isSubgroup)
            {
                if (charItem.id && charItem.id.indexOf("composite-") === 0)
                {
                    isCompositeSubgroup = YES;
                }
                else
                {
                    // Structural review: If it contains only leaf criteria (no nested Groups), collapse it
                    var subChars = charItem.characteristic || [];
                    var hasNestedGroups = NO;
                    for (var k = 0; k < subChars.length; k++)
                    {
                        var cItem = subChars[k];
                        if (cItem.resourceType === "Group" || cItem.characteristic || cItem.combinationMethod)
                        {
                            hasNestedGroups = YES;
                            break;
                        }
                    }
                    if (!hasNestedGroups && subChars.length > 0)
                    {
                        isCompositeSubgroup = YES;
                    }
                }
            }

            if (isCompositeSubgroup)
            {
                var subNode = [[FHIRCriteriaNode alloc] init];
                [subNode setRowType:CPRuleEditorRowTypeSimple];

                var isExclude = (charItem.exclude === true);

                if (!isExclude && charItem.characteristic)
                {
                    for (var m = 0; m < charItem.characteristic.length; m++)
                    {
                        if (charItem.characteristic[m].exclude === true)
                        {
                            isExclude = true;
                            break;
                        }
                    }
                }

                var presenceMode = @"all-present";
                if (isExclude || charItem.combinationMethod === "neither-of")
                {
                    presenceMode = @"neither-present";
                }
                else if (charItem.combinationMethod === "any-of")
                {
                    presenceMode = @"any-present";
                }
                [subNode setPresenceMode:presenceMode];

                var tokens = [];
                var subChars = charItem.characteristic || [];

                for (var m = 0; m < subChars.length; m++)
                {
                    var nestedChar = subChars[m];
                    var valueCodeableConcept = nestedChar.valueCodeableConcept;
                    if (valueCodeableConcept && valueCodeableConcept.coding)
                    {
                        var codings = valueCodeableConcept.coding;
                        for (var j = 0; j < codings.length; j++)
                        {
                            var coding = codings[j];
                            var codeVal = coding.code || "";
                            if (codeVal && codeVal.indexOf("[HPO_CODE_FOR_") !== 0)
                            {
                                tokens.push({
                                    "code": codeVal,
                                    "display": coding.display || codeVal
                                });
                            }
                            else
                            {
                                tokens.push({
                                    "code": @"HP:0000118",
                                    "display": coding.display || @"Symptom"
                                });
                            }
                        }
                    }
                }

                [subNode setHpoTokens:tokens];
                if (tokens.length > 0)
                {
                    [subNode setSymptomText:tokens[0].display];
                }

                [subNode updateCriteriaAndDisplayValues];
                [subrows addObject:subNode];
            }
            else if (isSubgroup)
            {
                var subNode = [self nodeFromFHIRGroup:charItem];
                if (subNode)
                {
                    [subrows addObject:subNode];
                }
            }
            else
            {
                var subNode = [[FHIRCriteriaNode alloc] init];
                [subNode setRowType:CPRuleEditorRowTypeSimple];

                var isExclude = (charItem.exclude === true);
                var presenceMode = @"all-present";
                if (isExclude || charItem.combinationMethod === "neither-of")
                {
                    presenceMode = @"neither-present";
                }
                else if (charItem.combinationMethod === "any-of")
                {
                    presenceMode = @"any-present";
                }
                [subNode setPresenceMode:presenceMode];

                var tokens = [];
                var valueCodeableConcept = charItem.valueCodeableConcept;
                if (valueCodeableConcept && valueCodeableConcept.coding)
                {
                    var codings = valueCodeableConcept.coding;
                    for (var j = 0; j < codings.length; j++)
                    {
                        var coding = codings[j];
                        var codeVal = coding.code || "";
                        if (codeVal && codeVal.indexOf("[HPO_CODE_FOR_") !== 0)
                        {
                            tokens.push({
                                "code": codeVal,
                                "display": coding.display || codeVal
                            });
                        }
                        else
                        {
                            tokens.push({
                                "code": @"HP:0000118",
                                "display": coding.display || @"Symptom"
                            });
                        }
                    }
                }

                [subNode setHpoTokens:tokens];
                if (tokens.length > 0)
                {
                    [subNode setSymptomText:tokens[0].display];
                }

                [subNode updateCriteriaAndDisplayValues];
                [subrows addObject:subNode];
            }
        }
        [node setSubrows:subrows];
    }
    else
    {
        [node setRowType:CPRuleEditorRowTypeSimple];
        var isExclude = (group.exclude === true);
        var presenceMode = @"all-present";
        if (isExclude || group.combinationMethod === "neither-of")
        {
            presenceMode = @"neither-present";
        }
        else if (group.combinationMethod === "any-of")
        {
            presenceMode = @"any-present";
        }
        [node setPresenceMode:presenceMode];

        var tokens = [];
        var valueCodeableConcept = group.valueCodeableConcept;
        if (valueCodeableConcept && valueCodeableConcept.coding)
        {
            var codings = valueCodeableConcept.coding;
            for (var j = 0; j < codings.length; j++)
            {
                var coding = codings[j];
                var codeVal = coding.code || "";
                if (codeVal && codeVal.indexOf("[HPO_CODE_FOR_") !== 0)
                {
                    tokens.push({
                        "code": codeVal,
                        "display": coding.display || codeVal
                    });
                }
                else
                {
                    tokens.push({
                        "code": @"HP:0000118",
                        "display": coding.display || @"Symptom"
                    });
                }
            }
        }
        [node setHpoTokens:tokens];
        if (tokens.length > 0)
        {
            [node setSymptomText:tokens[0].display];
        }

        [node updateCriteriaAndDisplayValues];
    }

    return node;
}

- (void)importFHIRGroup:(id)rootGroup
{
    if (!rootGroup) return;
    try
    {
        _isImportingJSON = YES;
        console.log("DEBUG [Frontend Import] Incoming rootGroup payload: ", rootGroup);

        // Resolve reference structures and inline deep composite subgroups
        var resolvedGroup = [self resolveContainedReferencesInGroup:rootGroup];
        var flattenedGroup = [self _flattenFHIRGroup:resolvedGroup];
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

- (CPMutableDictionary)compileGroupFromFlatNodes:(CPArray)flatNodes
{
    if ([flatNodes count] === 0) return [CPMutableDictionary dictionary];

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
            [refCharacteristic setObject:{ "text": @"Logical subgroup" } forKey:@"code"];
            [refCharacteristic setObject:{ "reference": "#" + subgroupID } forKey:@"valueReference"];
            [refCharacteristic setObject:NO forKey:@"exclude"];

            [characteristics addObject:refCharacteristic];
        }
        else
        {
            var tokenField = [childNode tokenField];
            var tokens = tokenField ? [tokenField objectValue] : [];

            // Multiple Tokens: Compile as a contained composite subgroup
            if (tokens.length > 1)
            {
                subgroupCounter.value = subgroupCounter.value + 1;
                var compositeID = "composite-symptom-" + subgroupCounter.value;

                var subGroup = [CPMutableDictionary dictionary];
                [subGroup setObject:@"Group" forKey:@"resourceType"];
                [subGroup setObject:compositeID forKey:@"id"];
                [subGroup setObject:@"conceptual" forKey:@"membership"];
                [subGroup setObject:@"person" forKey:@"type"];

                var subCombMethod = @"all-of";
                if ([[childNode presenceMode] isEqualToString:@"any-present"]) {
                    subCombMethod = @"any-of";
                }
                [subGroup setObject:subCombMethod forKey:@"combinationMethod"];

                var subCharacteristics = [CPMutableArray array];
                var isExclude = [[childNode presenceMode] isEqualToString:@"neither-present"];

                for (var k = 0; k < tokens.length; k++)
                {
                    var tok = tokens[k];
                    var subCharItem = [CPMutableDictionary dictionary];
                    [subCharItem setObject:{
                        "coding": [
                                   {
                                       "system": "http://snomed.info/sct",
                                       "code": "8116006",
                                       "display": "Phänotypisches Merkmal"
                                   }
                                   ]
                    } forKey:@"code"];

                    var codings = [{
                        "system": "http://human-phenotype-ontology.org",
                        "code": tok.code,
                        "display": tok.display
                    }];

                    [subCharItem setObject:{"coding": codings} forKey:@"valueCodeableConcept"];
                    [subCharItem setObject:isExclude forKey:@"exclude"];

                    var itemComb = isExclude ? @"neither-of" : @"all-of";
                    [subCharItem setObject:itemComb forKey:@"combinationMethod"];

                    [subCharacteristics addObject:subCharItem];
                }
                [subGroup setObject:subCharacteristics forKey:@"characteristic"];
                [containedArray addObject:subGroup];

                var refCharacteristic = [CPMutableDictionary dictionary];
                [refCharacteristic setObject:{"text": "Composite Logical subgroup"} forKey:@"code"];
                [refCharacteristic setObject:{"reference": "#" + compositeID} forKey:@"valueReference"];
                [refCharacteristic setObject:isExclude forKey:@"exclude"];

                [characteristics addObject:refCharacteristic];
            }
            else
            {
                // Single Token (Standard fallback pipeline)
                var codings = [];
                if (tokens.length > 0)
                {
                    var tok = tokens[0];
                    if (tok && tok.code)
                    {
                        codings.push({
                            "system": "http://human-phenotype-ontology.org",
                            "code": tok.code,
                            "display": tok.display
                        });
                    }
                }
                else
                {
                    var rawText = [childNode symptomText] || @"";
                    var clinicalTerm = [rawText stringByTrimmingCharactersInSet:[CPCharacterSet whitespaceAndNewlineCharacterSet]];
                    var hpoTermName = [clinicalTerm isEqualToString:@""] ? @"UNDEFINED" : clinicalTerm;

                    var formattedTerm = hpoTermName.toUpperCase().replace(/\s+/g, '_');
                    var hpoCodePlaceholder = "[HPO_CODE_FOR_" + formattedTerm + "]";

                    codings.push({
                        "system": "http://human-phenotype-ontology.org",
                        "code": hpoCodePlaceholder,
                        "display": hpoTermName
                    });
                }

                var charItem = [CPMutableDictionary dictionary];
                [charItem setObject:{
                    "coding": [
                               {
                                   "system": "http://snomed.info/sct",
                                   "code": "8116006",
                                   "display": "Phänotypisches Merkmal"
                               }
                               ]
                } forKey:@"code"];

                [charItem setObject:{"coding": codings} forKey:@"valueCodeableConcept"];

                var isExclude = [[childNode presenceMode] isEqualToString:@"neither-present"];
                [charItem setObject:isExclude forKey:@"exclude"];

                var combMethod = @"all-of";
                if ([[childNode presenceMode] isEqualToString:@"any-present"]) {
                    combMethod = @"any-of";
                } else if ([[childNode presenceMode] isEqualToString:@"neither-present"]) {
                    combMethod = @"neither-of";
                }
                [charItem setObject:combMethod forKey:@"combinationMethod"];

                [characteristics addObject:charItem];
            }
        }
    }

    [group setObject:characteristics forKey:@"characteristic"];
    return group;
}

- (BOOL)_groupContainsExclusions:(id)group
{
    if (!group) return NO;

    var characteristics = group.characteristic || [];
    for (var i = 0; i < characteristics.length; i++)
    {
        var charItem = characteristics[i];
        if (charItem.exclude === true || charItem.combinationMethod === "neither-of")
            return YES;

        var isSubgroup = (charItem.resourceType === "Group" || charItem.characteristic || charItem.combinationMethod);
        if (isSubgroup)
        {
            if ([self _groupContainsExclusions:charItem])
                return YES;
        }
    }
    return NO;
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

            // Structural identification of composite subgroups
            var isComposite = NO;
            if (flattenedSubgroup.id && flattenedSubgroup.id.indexOf("composite-") === 0)
            {
                isComposite = YES;
            }
            else
            {
                var subChars = flattenedSubgroup.characteristic || [];
                var hasNested = NO;
                for (var k = 0; k < subChars.length; k++)
                {
                    var cItem = subChars[k];
                    if (cItem.resourceType === "Group" || cItem.characteristic || cItem.combinationMethod)
                    {
                        hasNested = YES;
                        break;
                    }
                }
                if (!hasNested && subChars.length > 0)
                {
                    isComposite = YES;
                }
            }

            // Collapse logical blocks that are not defined as composite nodes
            var shouldFlatten = !isComposite &&
            (flattenedSubgroup.combinationMethod === group.combinationMethod) &&
            ![self _groupContainsExclusions:flattenedSubgroup];

            if (shouldFlatten)
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

// --------------------------------------------------------------------------------
// Tab 1 & Tab 2: HPO Browser Data Source & Search Operations
// --------------------------------------------------------------------------------

- (int)numberOfRowsInTableView:(CPTableView)tableView
{
    if (tableView === synonymsTableView) return [_synonyms count];
    if (tableView === xrefsTableView) return [_xrefs count];
    if (tableView === downstreamTableView) return [_downstreamTerms count];
    if (tableView === _crossmatchTableView) return [_crossmatchResults count];
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
    if (tableView === _crossmatchTableView) {
        if (row >= [_crossmatchResults count]) return nil;
        var item = _crossmatchResults[row];
        var ident = [tableColumn identifier];

        if (ident === @"status") {
            if (item.match_type === "inclusion") return "● Match (Inclusion)";
            if (item.match_type === "exclusion") return "● Match (Exclusion)";
            return "● Indifferent";
        }
        if (ident === @"patient_hpo") return item.patient_hpo;
        if (ident === @"patient_label") return item.patient_label;
        if (ident === @"matched_criterion") {
            if (item.matched_code) {
                return item.matched_label + " (" + item.matched_code + ")";
            }
            return "-";
        }
    }
    return nil;
}

- (void)tableView:(CPTableView)aTableView willDisplayCell:(id)aCell forTableColumn:(CPTableColumn)aTableColumn row:(int)aRow
{
    if (aTableView === _crossmatchTableView)
    {
        if (aRow >= [_crossmatchResults count]) return;
        var item = _crossmatchResults[aRow];
        var ident = [aTableColumn identifier];

        if (ident === @"status")
        {
            if (item.match_type === "inclusion")
            {
                [aCell setTextColor:[CPColor colorWithRed:0.0 green:0.6 blue:0.0 alpha:1.0]]; // Grün
            }
            else if (item.match_type === "exclusion")
            {
                [aCell setTextColor:[CPColor colorWithRed:0.8 green:0.0 blue:0.0 alpha:1.0]]; // Rot
            }
            else
            {
                [aCell setTextColor:[CPColor colorWithRed:0.5 green:0.5 blue:0.5 alpha:1.0]]; // Grau
            }
        }
        else
        {
            [aCell setTextColor:[CPColor blackColor]];
        }
    }
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

        [_dragSourcePanel setTerm:nil];
        return;
    }

    var item = [outlineView itemAtRow:selectedRow];
    var node = item ? [item representedObject] : nil;
    if (!node) return;

    [definitionTextView setString:[node definition] + ' (HP:' + [CPString stringWithFormat:"%07d", node.termId + 0] + ')' || @"No definition available."];
    [self fetchDownstreamForNode:node];
    [self fetchSynonymsForNode:node];
    [self fetchXrefsForNode:node];

    // Load standard selection credentials inside the active drag view panel
    var formattedId = "HP:" + [CPString stringWithFormat:"%07d", [node termId] + 0];
    var termDict = { "code": formattedId, "display": [node name] };
    [_dragSourcePanel setTerm:termDict];
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

- (void)runPatientMatchingAction:(id)sender
{
    [self updateFHIRGroupRepresentation];
    var rootGroup = [self compileGroupFromFlatNodes:_rootNodes];
    if (!rootGroup || [_rootNodes count] === 0) {
        alert("The Logical Eligibility Framework is empty. Please compile or add criteria first.");
        return;
    }

    var phenoText = [_phenopacketOutputTextView string];
    var phenopacket = nil;
    try {
        phenopacket = JSON.parse(phenoText);
    } catch(e) {
        alert("No valid Phenopacket JSON found. Please run the extraction on the 'Phenopacket / ICD Extractor' tab first.");
        return;
    }

    [_matchButton setEnabled:NO];
    [_matchButton setTitle:@"Matching..."];
    [_matchStatusLabel setStringValue:@"Running matching on server..."];
    [_matchStatusLabel setTextColor:[CPColor grayColor]];

    var request = [CPURLRequest requestWithURL:"/DBB/match_eligibility"];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    var jsGroup = [rootGroup JSObject];
    var payload = {
        "group": jsGroup,
        "phenopacket": phenopacket
    };
    var postData = [CPString stringWithString:JSON.stringify(payload)];
    [request setHTTPBody:postData];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
     {
        [_matchButton setEnabled:YES];
        [_matchButton setTitle:@"Run Patient Matching"];

        if (!error && data) {
            try {
                var parsedData = JSON.parse(data);

                var isEligible = parsedData.eligible === 1;
                if (isEligible) {
                    [_matchStatusLabel setStringValue:@"PATIENT ELIGIBLE (Match Succeeded)"];
                    [_matchStatusLabel setTextColor:[CPColor colorWithRed:0.0 green:0.6 blue:0.0 alpha:1.0]];
                } else {
                    [_matchStatusLabel setStringValue:@"PATIENT INELIGIBLE (Criteria Not Satisfied)"];
                    [_matchStatusLabel setTextColor:[CPColor colorWithRed:0.8 green:0.0 blue:0.0 alpha:1.0]];
                }

                _crossmatchResults = parsedData.phenotype_matches || [];
                [_crossmatchTableView reloadData];

            } catch (e) {
                alert("Error parsing matching response: " + e.message);
            }
        } else {
            var errorMsg = (error) ? [error localizedDescription] : @"Could not contact the database matching services.";
            [_matchStatusLabel setStringValue:@"Matching failed."];
            [_matchStatusLabel setTextColor:[CPColor colorWithRed:0.8 green:0.0 blue:0.0 alpha:1.0]];
            alert("Crossmatch Error:\n" + errorMsg);
        }
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

- (void)startExtractPulsatingAnimation
{
    [_extractStatusLabel setWantsLayer:YES];
    var layer = [_extractStatusLabel layer];
    [layer setDelegate:self];

    var pulseAnimation = [CABasicAnimation animationWithKeyPath:@"extractAlphaValue"];
    pulseAnimation._animationID = "extractPulse";
    [pulseAnimation setDelegate:self];
    [pulseAnimation setFromValue:1.0];
    [pulseAnimation setToValue:0.2];
    [pulseAnimation setDuration:0.6];
    [layer addAnimation:pulseAnimation forKey:@"extractAlphaValue"];
}

- (void)stopExtractPulsatingAnimation
{
    [[_extractStatusLabel layer] removeAnimationForKey:@"extractAlphaValue"];
    [_extractStatusLabel setAlphaValue:1.0];
}

- (void)setExtractAlphaValue:(float)val
{
    [_extractStatusLabel setAlphaValue:val];
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
    else if (anim._animationID === @"extractPulse") {
        var currentOpacity = [_extractStatusLabel alphaValue];
        var fromVal = (currentOpacity < 0.5) ? 0.2 : 1.0;
        var toVal   = (currentOpacity < 0.5) ? 1.0 : 0.2;

        var layer = [_extractStatusLabel layer];
        var pulseAnimation = [CABasicAnimation animationWithKeyPath:@"extractAlphaValue"];
        pulseAnimation._animationID = "extractPulse";
        [pulseAnimation setDelegate:self];
        [pulseAnimation setFromValue:fromVal];
        [pulseAnimation setToValue:toVal];
        [pulseAnimation setDuration:0.6];
        [layer addAnimation:pulseAnimation forKey:@"extractAlphaValue"];
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
