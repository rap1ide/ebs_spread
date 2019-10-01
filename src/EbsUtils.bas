Attribute VB_Name = "EbsUtils"
'  This macro collection lets you organize your tasks and schedules
'  for you with the evidence based design (EBS) approach by Joel Spolsky.
'
'  Copyright (C) 2019  Christian Weihsbach
'  This program is free software; you can redistribute it and/or modify
'  it under the terms of the GNU General Public License as published by
'  the Free Software Foundation; either version 3 of the License, or
'  (at your option) any later version.
'  This program is distributed in the hope that it will be useful,
'  but WITHOUT ANY WARRANTY; without even the implied warranty of
'  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
'  GNU General Public License for more details.
'  You should have received a copy of the GNU General Public License
'  along with this program; if not, write to the Free Software Foundation,
'  Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA
'
'  Christian Weihsbach, weihsbach.c@gmail.com
    
Option Explicit

Enum PropabilityChartMode
    ceChartModeLast = 1
    ceChartModeLastHundred = 2
    ceChartModeAll = 3
End Enum

Enum PropabilityChartScale
    ceChartScaleTime = -1
    ceChartScaleDate = 1
End Enum



Function HandleEbsSheetChanges(Target As Range)

    'This function handles all the value changes made to cells for ebs sheets.
    '
    'Input args:
    '  Target: The changed cell / range
    
    'Only manage changes to the table area of the ebs sheet (in the first place)
    Dim header As String
    header = Utils.GetListColumnHeader(Target)
    If Target.Count <> 1 Then
        Exit Function
    End If
    
    If StrComp(header, "") = 0 Then
        'Use a fallback for special cells that shall be managed but are not located in the table area (e.g. setting switches for charts).
        'Read the 'headers'of the changed cell which are left to the changed cell.
        header = Utils.GetLeftNeighbour(Target).Value
    End If
    
    'If changed cell is a part of one of the following columns manage change
    Select Case (header)
        Case Constants.EBS_SHOW_POOL_HEADER
            Call EbsUtils.ManagePoolVisibilityChange(Target)
        Case Constants.EBS_PROP_CHART_MODE_HEADER, Constants.EBS_PROP_CHART_SCALING_HEADER
            Call EbsUtils.PrintPropabilityChart(Target.parent)
    End Select
End Function



Function ManagePoolVisibilityChange(changedCell As Range)

    'This function handles switching settings in the main table regarding the pool visibility and adds datarows to the pool velocity chart as
    'well as setting their properties
    '
    'Input args:
    '  changedCell: Cell within the table for which the setting was switched (all cells of the column are reinvestigated)
    
    'Delete all the entries from the velocity histogram
    Call EbsUtils.ClearHistogramContents(changedCell.parent)
    
    Dim colData As Range
    Set colData = Utils.GetListColumn(changedCell.parent, Constants.EBS_MAIN_LIST_IDX, changedCell, ceData)
    
    'Find all pools which shall be displayed in the chart
    Dim selectedPools As Range
    Set selectedPools = Base.FindAll(colData, Constants.EBS_SHOW_POOL_TRUE)
    
    If selectedPools Is Nothing Then
        Exit Function
    End If
    
    'Find all pool cells that contain a deserialized array / data
    Set selectedPools = Base.FindAll(Utils.IntersectListColAndCells(changedCell.parent, Constants.EBS_MAIN_LIST_IDX, Constants.EBS_VELOCITY_POOL_HEADER, selectedPools), _
        Constants.SERIALIZED_ARRAY_REGEX, , ceRegex)
    
    If selectedPools Is Nothing Then
        Exit Function
    End If
    
    'Debug info
    'Debug.Print "Selected pools: " + selectedPools.Address
    
    'Get exponentially shaped transparency val distribution highlighting the 0% transparent (fully-visible) value more
    Dim transparencyVals() As Double
    transparencyVals = CalcExponentialTransparencyCurve(selectedPools.Count)
    
    Dim poolIdx As Integer
    poolIdx = 1
    
    Dim poolCell As Range
    For Each poolCell In selectedPools
        'Cycle through all the visible pool cells and add datarows
        'Debug.Print "poolCell: " + poolCell.Address
        
        'Retrieve the bare pool velocities
        Dim poolVals() As Double
        poolVals = Utils.CopyVarArrToDoubleArr(Utils.DeserializeArray(poolCell.Value))
        
        If Base.IsArrayAllocated(poolVals) Then
            Dim histoX() As Double
            Dim histoVal() As Long
            
            Dim ebsDate As Range
            Set ebsDate = Utils.IntersectListColAndCells(changedCell.parent, Constants.EBS_MAIN_LIST_IDX, Constants.EBS_RUN_DATE_HEADER, poolCell)
            
            'Calc the velocity histogram from the bare pool velocities (count and categorize)
            Call EbsUtils.CalcVelocityHistogram(poolVals, histoX, histoVal)
            
            'Print out the values
            Call EbsUtils.PrintVelocityHistogramDataRow(changedCell.parent, ebsDate.Value, histoX, histoVal, transparencyVals(poolIdx - 1))
            poolIdx = poolIdx + 1
        End If
    Next poolCell
End Function



Function RunEbs()

    'This function is the base function for EBS. For all contributors in the planning sheets with unfinished tasks
    'it collects all the data, calculates task remaining time to finish,
    'interpolates values for lean data storage and writes the data to the according tables. For every contributor a 'Sheduling (contributor)'
    'sheet is generated or updated.
    '
    'Input args:
    '  contributors: Array containing all the names of contributors for which EBS will be performed.
    
    Dim contributors As Variant
    Dim contribCells As Range
    Set contribCells = PlanningUtils.GetTaskListColumn(Constants.CONTRIBUTOR_HEADER, ceData)
    
    'Read all unique contributors
    Dim contribStrings As Collection
    Set contribStrings = Utils.ConvertRngToStrCollection(contribCells)
    Set contribStrings = Base.GetUniqueStrings(contribStrings)
    contributors = Base.CollectionToArray(contribStrings)
    
    'Check
    If Not Base.IsArrayAllocated(contributors) Then Exit Function
    
    'Add all necessary sheets
    Call PrepareEbsSheets(contributors)
    
    Dim contributor As Variant
    Dim sheet As Worksheet
    Dim eHash As String
    
    For Each contributor In contributors
        'Do seperate EBS for every contributor. Contributors'must not be mixed.
        
        Set sheet = GetEbsSheet(CStr(contributor))
            
        Dim ebsEntryCell As Range
        Dim entryRow As Range
        Dim dateCell As Range
        Dim velocityCell As Range
        Dim showPoolCell As Range
        Dim supportPointsCell As Range
        Dim hourEstimatesCell As Range
        Dim dateEstimatesCell As Range
        Dim eHashCell As Range
        
        'refurbish start
        Dim runDate As Date
        eHash = EbsUtils.GetLatestEbsRun(sheet, runDate)
        
        Dim createNewEntry As Boolean
        createNewEntry = ((Now - runDate) > EBS_TRACK_ENTRIES_DELTA_DAYS)
        
        If createNewEntry Then
            eHash = Utils.CreateHashString("e")
            runDate = Now
            'Generate a new line for a new run
            
            'Add a new EBS entry in the main list. The entry contains run time, used velocity pool data to make comparison of pools over time possible,
            'interpolated data for lean data storage
            
            Dim newFormattedNumber As String
            
            'The cell data for the new entry has to be returned, because the new row in list is added when the first data is entered in the row.
            'Currently not all data has successfully been fetched so we do not know whether to add a row or not.
            Dim gotData As Boolean
            gotData = Utils.GetNewEntry(sheet, Constants.EBS_MAIN_LIST_IDX, ebsEntryCell, newFormattedNumber)
            
            If Not gotData Then
                GoTo n03nextContributor
            End If
        Else
            'Use the latest ebs run entry
            'runDate = rundate
            Set eHashCell = Base.FindAll(EbsUtils.GetEbsMainListColumn(sheet, Constants.EBS_HASH_HEADER, ceAll), eHash)
            Set ebsEntryCell = EbsUtils.IntersectEbsMainListColumn(sheet, Constants.EBS_ENTRY_HEADER, eHashCell)
            'We found the entry. Create a new eHash now. eHash is updated even if the existing entry is only modified
            eHash = Utils.CreateHashString("e")
        End If
        
        'Prepare the cells data is written to
        Set entryRow = ebsEntryCell.EntireRow
        Set dateCell = EbsUtils.IntersectEbsMainListColumn(sheet, Constants.EBS_RUN_DATE_HEADER, entryRow)
        Set velocityCell = EbsUtils.IntersectEbsMainListColumn(sheet, Constants.EBS_VELOCITY_POOL_HEADER, entryRow)
        Set showPoolCell = EbsUtils.IntersectEbsMainListColumn(sheet, Constants.EBS_SHOW_POOL_HEADER, entryRow)
        Set supportPointsCell = EbsUtils.IntersectEbsMainListColumn(sheet, Constants.EBS_SUPPORT_POINT_HEADER, entryRow)
        Set hourEstimatesCell = EbsUtils.IntersectEbsMainListColumn(sheet, Constants.EBS_TIME_ESTIMATES_HEADER, entryRow)
        Set dateEstimatesCell = EbsUtils.IntersectEbsMainListColumn(sheet, Constants.EBS_DATE_ESTIMATES_HEADER, entryRow)
        Set eHashCell = EbsUtils.IntersectEbsMainListColumn(sheet, Constants.EBS_HASH_HEADER, entryRow)
        
        'Sanity check cells
        If ebsEntryCell Is Nothing Or _
            entryRow Is Nothing Or _
            dateCell Is Nothing Or _
            velocityCell Is Nothing Or _
            showPoolCell Is Nothing Or _
            supportPointsCell Is Nothing Or _
            hourEstimatesCell Is Nothing Or _
            dateEstimatesCell Is Nothing Or _
            eHashCell Is Nothing Then
            
            GoTo n03nextContributor
        End If
        
        'Get the velocity pool from finished tasks. Do not generate a pool if the old one is quite new (save execution time)
        Dim velocityPool() As Double
        Dim joined As String
        
        Dim fallback As Boolean
        fallback = False
        
        If Not createNewEntry Then
            'Read the velocity pool from cell
            velocityPool = Utils.CopyVarArrToDoubleArr(Utils.DeserializeArray(velocityCell.Value))
            
            'If the velocity entry could not be read from the cell use a fallback to create a new one
            If Not Base.IsArrayAllocated(velocityPool) Then fallback = True
        End If
        
        If createNewEntry Or fallback Then
            velocityPool = GenVelocityPool(CStr(contributor), Constants.EBS_VELOCITY_POOL_SIZE)
            'If no finished tasks are available generating the pool can still fail here - check this later
        End If
        
        'Add data to the "run data" table which lists all data for all unfinished tasks
        'Collect unfinished tasks, their hash, their priority and their elapsed time
        Dim runDataWritten As Boolean
        runDataWritten = False
        
        'The accumulated time estimates are estimates for every tasks considering it's place in the priority queue.
        'The estimate tells you when the task is finished if all other previous task have been finished before.
        Dim accumulatedTimeEstimates() As Double
        
        'The interpolated estimates are estimates, which hold data for specific support points to save memory in the spreadsheet. The data
        'stored for every EBS main entry is only interpolated data
        Dim supportPoints() As Double
        Dim interpolatedHourEstimates() As Double
        Dim interpolatedDateEstimates() As Date
        
        'Write the data to the EBS rundata list and return accumulated time estimates and interpolated date estimates for specified support points.
        'The written data is only valid for the current situation (current order of tasks in the queue, curren time values)
        
        If Base.IsArrayAllocated(velocityPool) Then
            runDataWritten = EbsUtils.WriteRunData(CStr(contributor), velocityPool, accumulatedTimeEstimates, supportPoints, interpolatedHourEstimates, _
                interpolatedDateEstimates)
        Else
            runDataWritten = False
        End If
        
        If createNewEntry Or fallback Then
            'Write data to the main table
            ebsEntryCell.Value = newFormattedNumber
            
            'Generate a hash for each contributor for every ebs run
            eHashCell.Value = eHash
            dateCell.Value = runDate
            
            If Base.IsArrayAllocated(velocityPool) Then
                velocityCell.Value = Utils.SerializeArray(velocityPool)
                showPoolCell.Value = Constants.EBS_SHOW_POOL_TRUE
            Else
                velocityCell.Value = "<NO_POOLDATA_AVAILABLE>"
                showPoolCell.Value = Constants.EBS_SHOW_POOL_FALSE
            End If
        End If
            
        If runDataWritten Then
            'Calculate and write interpolated time estimates

            'Write interpolated vals to sheet
            If Base.IsArrayAllocated(interpolatedHourEstimates) Then
                supportPointsCell.Value = Utils.SerializeArray(supportPoints)
            Else
                supportPointsCell.Value = Constants.N_A
            End If
            
            If Base.IsArrayAllocated(interpolatedHourEstimates) Then
                hourEstimatesCell.Value = Utils.SerializeArray(interpolatedHourEstimates)
            Else
                hourEstimatesCell.Value = Constants.N_A
            End If
            
            If Base.IsArrayAllocated(interpolatedDateEstimates) Then
                dateEstimatesCell.Value = Utils.SerializeArray(interpolatedDateEstimates)
            Else
                dateEstimatesCell.Value = Constants.N_A
            End If
        End If
                
        'Redraw the velocity pool and the propability chart. Has to be done when run ebs is run via Utils.RunTryCatchedCall
        Call ManagePoolVisibilityChange(showPoolCell)
        Call EbsUtils.PrintPropabilityChart(sheet)
        
        'Update the ebs columns on planning sheet
        Call PlanningUtils.UpdateAllEbsCols
        Call PlanningUtils.CollectTotalTimesSpent
n03nextContributor:
    Next contributor
End Function



Function PrepareEbsSheets(ByRef contributors As Variant)
    'This function adds new contributor EBS / sheduling sheets if not existing.
    '
    'Input args:
    '  contributors: Array containing all the names of contributors for which an EBS sheet is needed.
    
    'Check input
    If Not Base.IsArrayAllocated(contributors) Then
        Exit Function
    End If
    
    Dim contributor As Variant

    For Each contributor In contributors
        Call EbsUtils.GetEbsSheet(CStr(contributor))
    Next contributor
End Function



Function GetEbsSheet(contributor As String) As Worksheet
    'This function adds a new contributor EBS / sheduling sheet if not existing or returns a reference to an existing sheet.
    '
    'Input args:
    '  contributors: Array containing all the names of contributors for which an EBS sheet is needed.
        
    If Utils.SheetExists(BuildContributorSheetName(contributor)) Then
        Set GetEbsSheet = ThisWorkbook.Worksheets(BuildContributorSheetName(contributor))
    Else
        'Add a new worksheet if no worksheet exists
        ThisWorkbook.Worksheets(Constants.EBS_SHEET_TEMPLATE_NAME).Copy After:=ThisWorkbook.Worksheets(Constants.PLANNING_SHEET_NAME)
    
        'Go back to overview worksheet as copying jumps to the new sheet
        ThisWorkbook.Worksheets(PLANNING_SHEET_NAME).Activate
    
        Dim sheet As Worksheet
        Set sheet = ThisWorkbook.Worksheets(Constants.EBS_SHEET_TEMPLATE_NAME + " (2)")
        sheet.name = BuildContributorSheetName(contributor)
        sheet.Visible = xlSheetVisible
        Set GetEbsSheet = sheet
    End If
End Function



Function GetEbsMainListColumn(sheet As Worksheet, colIdentifier As Variant, rowIdentifier As ListRowSelect) As Range
    'Wrapper to read column of the ebs main list
    '
    'Input args:
    '  sheet:                  The sheet of a contributor
    '  colIdentifier:          A constant specifying the header name of a column (data from this header column is retunred)
    '  rowIdentifier:              The row range of data returned
    '
    'Output args:
    '  GetEbsMainListColumn:   Column range with specified header
    
    Set GetEbsMainListColumn = Utils.GetListColumn(sheet, Constants.EBS_MAIN_LIST_IDX, colIdentifier, rowIdentifier)
End Function



Function GetRunDataListColumn(sheet As Worksheet, colIdentifier As Variant, rowIdentifier As ListRowSelect) As Range
    'Wrapper to read column of the ebs rundata list
    '
    'Input args:
    '  sheet:                  The sheet of a contributor
    '  colIdentifier:          A constant specifying the header name of a column (data from this header column is retunred)
    '  rowIdentifier:              The row range of data returned
    '
    'Output args:
    '  GetRunDataListColumn:   Column range with specified header
    
    Set GetRunDataListColumn = Utils.GetListColumn(sheet, Constants.EBS_RUNDATA_LIST_IDX, colIdentifier, rowIdentifier)
End Function



Function IntersectEbsMainListColumn(sheet As Worksheet, colIdentifier As Variant, rowIdentifier As Range) As Range
    'Intersects a ebs main list column and the given row range in 'rowIdentifier'
    'Used to return specific cells inside the list
    '
    'Input args:
    '  sheet:                      The sheet of a contributor
    '  colIdentifier:              A constant specifying the header name of a column (data from this header column is retunred)
    '  rowIdentifier:              The row range of data returned
    '
    'Output args:
    '  IntersectEbsMainListColumn:   Column range with specified header
    
    Set IntersectEbsMainListColumn = Utils.IntersectListColAndCells(sheet, Constants.EBS_MAIN_LIST_IDX, colIdentifier, rowIdentifier)
End Function



Function IntersectRunDataColumn(sheet As Worksheet, colIdentifier As Variant, rowIdentifier As Range) As Range
    'Intersects a ebs main list column and the given row range in 'rowIdentifier'
    'Used to return specific cells inside the list
    '
    'Input args:
    '  sheet:                      The sheet of a contributor
    '  colIdentifier:              A constant specifying the header name of a column (data from this header column is retunred)
    '  rowIdentifier:              The row range of data returned
    '
    'Output args:
    '  IntersectRunDataColumn:   Column range with specified header
    
    Set IntersectRunDataColumn = Utils.IntersectListColAndCells(sheet, Constants.EBS_RUNDATA_LIST_IDX, colIdentifier, rowIdentifier)
    
    'Debug info
    'Debug.Print "Intersecting col: " + EbsUtils.GetRunDataListColumn(sheet, colIdentifier, ceAll).Address
    'Debug.Print "Intersecting cell: " + rowIdentifier.Address
End Function



Function GenVelocityPool(contributor As String, N As Long) As Double()
    'Generates a velocity pool for the specified contributor. The pool consists of velocity data from finished tasks of the contributor.
    'One can generate random velocity data in addtion to real data if not enough data is present
    '
    'Input args:
    '  contributor:        The contributor whose pool shall be generated
    '  N:                  A constant specifying the header name of a column (data from this header column is retunred)
    '
    'Output args:
    '  GenVelocityPool:    Array containing double pool velocities (size N)
    
    'Init output
    Dim velocities() As Double
    GenVelocityPool = velocities
    
    'Check args
    If StrComp(contributor, "") = 0 Or N < 1 Then
        Exit Function
    End If
    
    Dim finishedTasks As Range
    Dim contributorTasks As Range
    Dim hashCells As Range
    Dim dateCells As Range
    
    'Search all n last finished tasks on planning sheet which have a valid velocity value
    Set finishedTasks = PlanningUtils.GetFinishedTasks()
    
    'Debug info
    'Debug.Print "finished: " + finishedTasks.Address
    
    Set contributorTasks = Base.FindAll( _
        PlanningUtils.GetTaskListColumn(Constants.CONTRIBUTOR_HEADER, ceData), _
        contributor)
    
    'Debug info
    'Debug.Print CStr(contributor) + ": " + contributorTasks.Address
    
    'Break if no finished tasks or tasks for the contributor are found
    If finishedTasks Is Nothing Or contributorTasks Is Nothing Then
        Exit Function
    End If
    
    'Now read the resulting hash cells: The hashes of all finished tasks for the current contributor
    Set hashCells = IntersectN( _
        PlanningUtils.GetTaskListColumn(Constants.T_HASH_HEADER, ceData), _
        IntersectN(finishedTasks.EntireRow, _
        contributorTasks.EntireRow))
    
    'Debug info
    'Debug.Print "hashCells: " + hashCells.Address
    
    If hashCells Is Nothing Then
        Exit Function
    End If
    
    Dim hashes() As String
    hashes = Utils.ConvertRangeValsToArr(hashCells)
        
    Set dateCells = Base.IntersectN( _
        hashCells.EntireRow, _
        PlanningUtils.GetTaskListColumn(Constants.TASK_FINISHED_ON_HEADER, ceData))
    
    Dim dates() As Date
    dates = Utils.CopyVarArrToDateArr(Utils.ConvertRangeValsToArr(dateCells))
    
    'Sort the hashes ascending to the finished date. Sort hashes accordingly to keep reference
    Call Base.QuickSort(dates, ceDescending, , , hashes)
    
    Dim hash As String
    Dim hashIdx As Long
    Dim veloIdx As Long
    veloIdx = 0
    
    Dim upperLimit As Long
    
    'Get all velocities out of the array, if less than n velocities exist. Get max n velocities if more velocities are avialable
    If UBound(hashes) < N Then
        upperLimit = UBound(hashes)
    Else
        upperLimit = N
    End If
    
    Dim velocity As Double
    Dim hashSheet As Worksheet
    
    For hashIdx = 0 To upperLimit
        Set hashSheet = TaskUtils.GetTaskSheet(CStr(hashes(hashIdx)))
        
        'Read the velocity from the sheet's cell
        velocity = TaskUtils.GetVelocity(hashSheet)
        
        'Check velocity val - cannot be negative
        If velocity <> -1 Then
            ReDim Preserve velocities(veloIdx)
            velocities(veloIdx) = velocity
            veloIdx = veloIdx + 1
        End If
    Next hashIdx
    
    'Generate additional velocites if not enough are available
    If UBound(velocities) < N And Constants.EBS_GENERATE_RND_VELOCITIES Then
        Dim genVelocityIdx As Long
        
        For genVelocityIdx = UBound(velocities) + 1 To N
            ReDim Preserve velocities(genVelocityIdx)
            velocities(genVelocityIdx) = EbsUtils.GenRandomVelocity(Constants.EBS_UPPER_RND_VELOCITY_LIMIT, Constants.EBS_LOWER_RND_VELOCITY_LIMIT)
        Next genVelocityIdx
    End If
    
    GenVelocityPool = velocities
End Function



Function GenRandomVelocity(upperLimit As Double, lowerLimit As Double) As Double
    Call Randomize
    'Generates a single random velocity within specified limits.
    '
    'Input args:
    '  upperLimit:         Upper value limit (exclusive)
    '  lowerLimit:         Lower value limit (inclusive)
    '
    'Output args:
    '  GenRandomVelocity:  Single velocity (double) val
    
    'Use a uniform distribution in log scale to get equal count of values for lets say (0.2 to 1) and (1 to 5) as these are equally bad estimate ranges
    GenRandomVelocity = 10 ^ ((Log10(upperLimit) - Log10(lowerLimit)) * Rnd() + Log10(lowerLimit))
End Function



Function GenRandomIndex(upperLimit As Integer) As Integer
    'Generates a random index from 0 to 'upperLimit'
    '
    'Input args:
    '  upperLimit:      Upper value limit (exclusive)
    '
    'Output args:
    '  GenRandomIndex:  Returned index
    
    Call Randomize
    GenRandomIndex = Int((upperLimit - 0 + 1) * Rnd + 0)
End Function



Function CalcVelocityHistogram(velocities() As Double, ByRef histoX() As Double, ByRef histoVal() As Long)
    'This function uses given velocities and returns a histogram (specified by a constant) in log scaling.
    'Log scaling is needed if one wants to see the quality of velocities linearily in the printed chart:
    'Velocities (0.2 to 0.4) are equally good as (2.5 to 5)
    'To see the result print 'histoVal'(count of velocities) over 'histoX'in a chart with bars
    '
    'Input args:
    '  velocities: Array containing the velocity values
    '
    'Output args:
    '  histoX:     Setpoint array returned
    '  histoVal:   histogram value array returned
    
    'Convert the specified histogram limits to log scale
    Dim logMin As Double
    logMin = Log10(Constants.EBS_LOWER_HISTOGRAM_LIMIT)
    
    Dim logMax As Double
    logMax = Log10(Constants.EBS_UPPER_HISTOGRAM_LIMIT)
    
    'Calc the width of a histogram bar
    Dim logDeltaSpan As Double
    logDeltaSpan = (logMax - logMin) / (Constants.EBS_HISTOGRAM_BAR_COUNT - 1)
    
    Dim xValIdx As Integer
    'Redim and reset to zero here
    ReDim histoX(Constants.EBS_HISTOGRAM_BAR_COUNT - 1)
    
    'Fill the x-values here
    For xValIdx = 0 To UBound(histoX)
        histoX(xValIdx) = 10 ^ (logMin + xValIdx * logDeltaSpan)
    Next xValIdx
    
    'Redim and reset to zero here
    ReDim histoVal(Constants.EBS_HISTOGRAM_BAR_COUNT - 1)
        
    Dim velo As Variant
    Dim logVelo As Double
    Dim bar As Integer
    
    For Each velo In velocities
        logVelo = Log10(CDbl(velo))
        
        'Sort very high and low velocities to the outer bars
        If logVelo < logMin Then
            logVelo = logMin + logDeltaSpan / 2
        ElseIf logVelo > logMax Then
            logVelo = logMax - logDeltaSpan / 2
        End If
        
        'Sort velocity values to bars
        bar = CInt((logVelo - logMin) / logDeltaSpan)
        'Increase velocity count of the selected bar
        histoVal(bar) = histoVal(bar) + 1
    Next velo
End Function



Function ClearHistogramContents(sheet As Worksheet)
    'This function clears data of velocity histogram chart
    '
    'Input args:
    '  sheet:  Ebs sheet containing the velocity histogram
    
    Dim veloChart As Chart
    Set veloChart = sheet.ChartObjects(Constants.EBS_VELO_CHART_INDEX).Chart
    veloChart.ChartArea.ClearContents
End Function



Function PrintVelocityHistogramDataRow(sheet As Worksheet, datee As Date, histoX() As Double, histoVal() As Long, Optional transparency As Double = 0)
    'Add a data set to the velocity histogram. Name of set is set according to the passed date. Transparency of lines can additionally be set.
    '
    'Input args:
    '  sheet:          Array containing the velocity values
    '  datee:          Generation date of velocity pool data
    '  histoX:         Histogram x-values
    '  histoVal:       Histogram y-values
    '  transparency:   Transparency value
    
    'Get chart and colors
    Dim veloChart As Chart
    Set veloChart = sheet.ChartObjects(Constants.EBS_VELO_CHART_INDEX).Chart
    
    'Retrieve the colors
    Dim accentColor As Long
    Dim lightColor As Long
    Dim commonColor As Long
    
    accentColor = SettingUtils.GetColors(ceAccentColor)
    commonColor = SettingUtils.GetColors(ceCommonColor)
    lightColor = SettingUtils.GetColors(ceLightColor)
    
    
    'Add a new series
    Dim seriees As Series
    Call veloChart.SeriesCollection.NewSeries

    Dim seriesCount As Long
    seriesCount = veloChart.SeriesCollection.Count
    
    'Set the properties of all existing series (common color, gray)
    Dim serIdx As Long
    For serIdx = 1 To seriesCount - 1
        Set seriees = veloChart.SeriesCollection(serIdx)
        With seriees
            .Format.Line.Weight = 1.75
            .Format.Line.Visible = msoTrue
            .Format.Line.ForeColor.RGB = commonColor
            .Format.Line.transparency = transparency
            .MarkerBackgroundColor = lightColor
    End With
    Next serIdx
    
    'Now prepare the new series
    'Rescale histo data (count of velocities) to (0 to 1)
    Dim maxVal As Long
    maxVal = Base.Max(histoVal)
    
    Dim scaledHisto() As Double
    ReDim scaledHisto(UBound(histoVal))
    
    Dim bar As Integer
    
    For bar = 0 To UBound(scaledHisto)
        scaledHisto(bar) = histoVal(bar) / CDbl(maxVal)
    Next bar
    
    Set seriees = veloChart.SeriesCollection(seriesCount)
    
    'Set the series values
    seriees.XValues = histoX
    seriees.Values = scaledHisto
    seriees.name = "Velo pool on: " + CStr(datee)
    
    'Format the latest dataset with accent color
    With seriees
        .Format.Line.Weight = 1.75
        .Format.Line.Visible = msoTrue
        .Format.Line.ForeColor.RGB = accentColor
        .Format.Line.transparency = transparency
        .MarkerBackgroundColor = lightColor
    End With
End Function



Function BuildContributorSheetName(contributor As String) As String
    'This function builds the contributor sheet name e.g. "Sheduling (Marc)". Too long contributor names will be cropped.
    '
    'Input args:
    '  contributor
    '
    'Output args:
    '  BuildContributorSheetName:  The returned sheet name
    
    Const SHEET_NAME_MAX_LENGTH As Integer = 31
    
    'Init output
    BuildContributorSheetName = ""
    
    'Check args
    If StrComp(contributor, "") = 0 Then
        Exit Function
    End If
    
    Dim sheetName As String
    sheetName = Constants.EBS_SHEET_PREFIX + " (" + contributor + ")"
        
    Dim preSuffixLen As Long
    preSuffixLen = Len(sheetName) - Len(contributor)
    
    If preSuffixLen > SHEET_NAME_MAX_LENGTH Then
        'The pre and postfix together too long
        Exit Function
    End If
    
    If Len(sheetName) > SHEET_NAME_MAX_LENGTH Then
        'Sheet name is too long. Crop the contributor name to make it fit
        sheetName = Constants.EBS_SHEET_PREFIX + " (" + Left(contributor, SHEET_NAME_MAX_LENGTH - preSuffixLen) + ")"
    End If
    
    BuildContributorSheetName = sheetName
End Function



Function WriteRunData(contributor As String, contribPool() As Double, ByRef accumulatedTimeEstimates() As Double, _
    ByRef supportPoints() As Double, ByRef interpolatedHourEstimates() As Double, ByRef interpolatedDateEstimates() As Date) As Boolean
    'This function is part of the ebs calculation. It takes pool velocities of a contributor and calculates ebs data for all unfinished tasks.
    'This is THE core function for ebs.
    '
    'Input args:
    '  contributor:                Contributor name. Used to fetch all unfinished tasks from this contributor
    '  contribPool:                The pool of the contributor to be used
    '
    'Output args:
    '  accumulatedTimeEstimates:   Array of simulated accumulated time estimates of remaining task times for all tasks in the queue
    '  supportPoints:              Propability Support points used to interpolate heavy simulation data to lightweight data
    '  interpolatedHourEstimates:  The hours a user needs to complete all his or her tasks
    '  interpolatedDateEstimates:  The date a user will finish his or her tasks (relates to interpolated hours, but takes holidays and meetings
    '                              into account.
    
    'Init output
    WriteRunData = False
    
    'Check args
    If StrComp(contributor, "") = 0 Then Exit Function

    'Clear the run data list
    Dim sheet As Worksheet
    Set sheet = EbsUtils.GetEbsSheet(contributor)
    
    'Get the run data data table / list object
    Dim lo As ListObject
    Set lo = sheet.ListObjects(Constants.EBS_RUNDATA_LIST_IDX)
    
    If Not lo.DataBodyRange Is Nothing Then
        lo.DataBodyRange.Delete
    End If
    
    Dim finishedTasks As Range
    Dim unfinishedTasks As Range
    Dim unfinishedTasksPrioCells As Range
    
    Dim contributorTasks As Range
    Dim hashCells As Range
    
    'Search all unfinished tasks on planning sheet
    Set finishedTasks = PlanningUtils.GetFinishedTasks()
    Set unfinishedTasks = PlanningUtils.GetUnfinishedTasks()
    Set contributorTasks = Base.FindAll( _
        PlanningUtils.GetTaskListColumn(Constants.CONTRIBUTOR_HEADER, ceData), contributor)
    
    'Break if no unfinished task for the current contributor is found
    If unfinishedTasks Is Nothing Or contributorTasks Is Nothing Then
        Exit Function
    End If
    
    'Now read the resulting hash cells: The hashes of all unfinished tasks for the current contributor
    Set hashCells = Base.IntersectN(unfinishedTasks.EntireRow, contributorTasks.EntireRow)
    Set hashCells = Base.IntersectN(PlanningUtils.GetTaskListColumn(Constants.T_HASH_HEADER, ceData), hashCells)
    
    If hashCells Is Nothing Then
        'If no intersecting cells can be found ...
        Exit Function
    End If

    Set unfinishedTasksPrioCells = IntersectN( _
        hashCells.EntireRow, _
        PlanningUtils.GetTaskListColumn(Constants.TASK_PRIORITY_HEADER, ceData))
    
    'Sort the hashes by their tasks' prios
    Dim hashes As Variant
    Dim prios As Variant
    hashes = Utils.ConvertRangeValsToArr(hashCells)
    prios = Utils.CopyVarArrToDoubleArr(Utils.ConvertRangeValsToArr(unfinishedTasksPrioCells))

    Call Base.QuickSort(prios, ceDescending, , , hashes)
    
    'Start editing the run data
    
    Dim hashIdx As Long
    
    'Init the accumulatedTimes here
    ReDim accumulatedTimeEstimates(Constants.EBS_VELOCITY_PICKS - 1)
    
    Dim newEntryCell As Range
    Dim runDataRow As Range
    Dim hashEntryCell As Range
    Dim prioEntryCell As Range
    Dim spentTimeEntryCell As Range
    Dim userEstimateCell As Range
    Dim remainingTimeEstimateCell As Range
    Dim monteCarloEstimateCell As Range
    Dim accumulatedEstimatesCell As Range
    Dim supportPointsCell As Range
    Dim interpolatedEstimatesCell As Range
    Dim interpolatedDatesEstimatesCell As Range
    
    Dim createNewEntry As Boolean
    Dim newFormattedEntry As String
    
    Dim currentHash As String
    Dim userEstimate As Double
    Dim spentTime As Double
    Dim monteCarloTimeEstimates() As Double
    Dim remainingTimeEstimates() As Double
    
    'Stored values to increase speed for 'MultiMapHoursToDate' algorithm
    Dim lastRemainingHours() As Double
    Dim lastMappedDates() As Date
            
    Dim entriesWritten As Long
    entriesWritten = 0
    
    'Read the support points
    supportPoints = Utils.CopyVarArrToDoubleArr(Constants.EBS_SUPPORT_PROPABILITIES)
            
    For hashIdx = 0 To UBound(hashes)
        'For all found unfinished tasks iterate
                
        'Now start ebs calculations task-wise
        currentHash = CStr(hashes(hashIdx))
                      
        'Base of the calculations is the estimate of the user
        userEstimate = -1
        userEstimate = TaskUtils.GetEstimate(TaskUtils.GetTaskSheet(currentHash))
        
        If userEstimate <> -1 Then
            'Valid user estimate was found
        
            'Set the spent time of the task
            spentTime = -1
            spentTime = TaskUtils.GetTaskTotalTime(TaskUtils.GetTaskSheet(currentHash))
             
            'Calculate time estimates: Total time needed to complete the task
            Erase monteCarloTimeEstimates
            monteCarloTimeEstimates = EbsUtils.GetMonteCarloTimeEstimates(userEstimate, contribPool, Constants.EBS_VELOCITY_PICKS)
            
            'Calculate the remaining times: (Monte carlo estimate) - (remaining time)
            Erase remainingTimeEstimates
            remainingTimeEstimates = Utils.CopyVarArrToDoubleArr(Base.CalcOnArray("EbsUtils.CalcRemainingTime", monteCarloTimeEstimates, spentTime))
             
            'Calculate accumulated time estimates: The array values increase every iteration, do not clear
            accumulatedTimeEstimates = Utils.CopyVarArrToDoubleArr( _
                Base.CalcOnArray("Base.CalcAddition", accumulatedTimeEstimates, remainingTimeEstimates))
             
            'Clear data and interpolate the accumulated time estimates (crop data)
            Erase interpolatedHourEstimates
            interpolatedHourEstimates = EbsUtils.InterpolateEstimates(supportPoints, accumulatedTimeEstimates)
             
            Dim calendarItems As Outlook.Items
            
            'Fetch the items for the current contributor
            Set calendarItems = CalendarUtils.GetCalItems(contributor, Constants.BUSY_AT_OPTIONAL_APPOINTMENTS)
             
            'Take the interpolated time estimates and calc a date: The used algorithm makes use of the fact, that the estimates are
            'sorted ascending (starting point for date calculation is the previous successfully calculated date)
            
            'Reset the values and calc dates
            Erase interpolatedDateEstimates

            interpolatedDateEstimates = CalendarUtils.MultiMapHoursToDate( _
                contributor, _
                calendarItems, _
                interpolatedHourEstimates, _
                Now, _
                lastRemainingHours, lastMappedDates, _
                SettingUtils.GetContributorApptOnOffset(contributor, ceOnset), _
                SettingUtils.GetContributorApptOnOffset(contributor, ceOffset))
                
            'Store the mapped dates and its' input values for next iteration to improve speed
            lastRemainingHours = interpolatedHourEstimates
            lastMappedDates = interpolatedDateEstimates
        Else
            'No valid estimate found
            Debug.Print ("Skipped hash for ebs calculation: " + currentHash)
            GoTo nextHash0a1
            Stop
        End If
        
        'Add the data to the list
        
        'This call only retrieves the next line and number the entry will get. Entry will only be added if all data can successfully be
        'calculated and fetched. With the 'newEntryCell'all the cells where data is inserted can be searched by intersection
        createNewEntry = Utils.GetNewEntry(sheet, Constants.EBS_RUNDATA_LIST_IDX, newEntryCell, newFormattedEntry)
        If Not createNewEntry Then
            'If no new entry could be inserted there is a more severe problem
            Exit Function
        End If
        
        'Intersect cells to prepare data insertion
        Set runDataRow = newEntryCell.EntireRow
        Set hashEntryCell = EbsUtils.IntersectRunDataColumn(sheet, Constants.EBS_RUNDATA_T_HASH_HEADER, _
            runDataRow)
        Set prioEntryCell = EbsUtils.IntersectRunDataColumn(sheet, Constants.EBS_RUNDATA_PRIORITY_HEADER, _
            runDataRow)
        Set spentTimeEntryCell = EbsUtils.IntersectRunDataColumn(sheet, Constants.EBS_RUNDATA_TIME_SPENT_HEADER, _
            runDataRow)
        Set userEstimateCell = EbsUtils.IntersectRunDataColumn(sheet, Constants.TASK_ESTIMATE_HEADER, _
            runDataRow)
        Set remainingTimeEstimateCell = EbsUtils.IntersectRunDataColumn(sheet, Constants.EBS_RUNDATA_REMAINING_TIME_POOL_HEADER, _
            runDataRow)
        Set monteCarloEstimateCell = EbsUtils.IntersectRunDataColumn(sheet, Constants.EBS_RUNDATA_ESTIMATES_POOL_HEADER, _
            runDataRow)
        Set accumulatedEstimatesCell = EbsUtils.IntersectRunDataColumn(sheet, Constants.EBS_RUNDATA_ACCUMULATED_TIME_POOL_HEADER, _
            runDataRow)
        Set interpolatedEstimatesCell = EbsUtils.IntersectRunDataColumn(sheet, Constants.EBS_RUNDATA_INTERPOLATED_TIME_HEADER, _
            runDataRow)
        Set interpolatedDatesEstimatesCell = EbsUtils.IntersectRunDataColumn(sheet, Constants.EBS_RUNDATA_INTERPOLATED_DATES_HEADER, _
            runDataRow)
        Set supportPointsCell = EbsUtils.IntersectRunDataColumn(sheet, Constants.EBS_SUPPORT_POINT_HEADER, _
            runDataRow)
        
        If newEntryCell Is Nothing Or _
        runDataRow Is Nothing Or _
        hashEntryCell Is Nothing Or _
        prioEntryCell Is Nothing Or _
        spentTimeEntryCell Is Nothing Or _
        userEstimateCell Is Nothing Or _
        remainingTimeEstimateCell Is Nothing Or _
        monteCarloEstimateCell Is Nothing Or _
        accumulatedEstimatesCell Is Nothing Or _
        supportPointsCell Is Nothing Or _
        interpolatedEstimatesCell Is Nothing Or _
        interpolatedDatesEstimatesCell Is Nothing Then
            'If a cell could not be found there is a more severe problem.
            Exit Function
            Stop
        End If
        
        'Set values to cells. If values are not available write 'N/A':
        newEntryCell.Value = newFormattedEntry
        
        If IsNumeric(prios(hashIdx)) Then prioEntryCell.Value = prios(hashIdx) Else prioEntryCell.Value = Constants.N_A
        If SanityChecks.CheckHash(currentHash) Then hashEntryCell.Value = currentHash Else hashEntryCell.Value = Constants.N_A
        If IsNumeric(spentTime) Then spentTimeEntryCell.Value = spentTime Else spentTimeEntryCell.Value = Constants.N_A
        If userEstimate <> -1 Then userEstimateCell.Value = userEstimate Else userEstimateCell.Value = Constants.N_A
        If Base.IsArrayAllocated(monteCarloTimeEstimates) Then monteCarloEstimateCell.Value = Utils.SerializeArray(monteCarloTimeEstimates) Else _
            monteCarloEstimateCell.Value = Constants.N_A
        If Base.IsArrayAllocated(remainingTimeEstimates) Then remainingTimeEstimateCell.Value = Utils.SerializeArray(remainingTimeEstimates) Else _
            remainingTimeEstimateCell.Value = Constants.N_A
        If Base.IsArrayAllocated(accumulatedTimeEstimates) Then accumulatedEstimatesCell.Value = Utils.SerializeArray(accumulatedTimeEstimates) Else _
            accumulatedEstimatesCell.Value = Constants.N_A
        
        'Write the interpolated estimates
        If Base.IsArrayAllocated(supportPoints) Then supportPointsCell.Value = Utils.SerializeArray(supportPoints) Else _
            supportPointsCell.Value = Constants.N_A
        If Base.IsArrayAllocated(interpolatedHourEstimates) Then interpolatedEstimatesCell.Value = Utils.SerializeArray(interpolatedHourEstimates) Else _
            interpolatedEstimatesCell.Value = Constants.N_A
        If Base.IsArrayAllocated(interpolatedDateEstimates) Then interpolatedDatesEstimatesCell.Value = Utils.SerializeArray(interpolatedDateEstimates) Else _
            interpolatedDatesEstimatesCell.Value = Constants.N_A
        
        entriesWritten = entriesWritten + 1
nextHash0a1:
    Next hashIdx
    
    'If any entry has been written return true
    If entriesWritten > 0 Then
        WriteRunData = True
    Else
        WriteRunData = False
        Stop
    End If
End Function



Function InterpolateEstimates(supportPoints() As Double, inputEstimates() As Double) As Double()
    'For given support points and input estimates this function crops the data and returnes interpolated values
    'All given estimates will be mapped to a propability from 0 to 1 according to the count of given estimates. E.g. three estimates will be mapped to [0.0, 0.5, 1.0]
    '
    'Input args:
    '  supportPoints:  Propability Support points used to interpolate heavy simulation data to lightweight data
    '  inputEstimates: The estimates that shall be interpolated
    'Output args:
    '  InterpolateEstimates: The interpolated values. Can be more or less than the specified input values. Be careful with extrapolation (works but
    '  can result in unreliable data)
    
    'Init output
    Dim interpolated() As Double
    InterpolateEstimates = interpolated
    
    'Check args
    If Not Base.IsArrayAllocated(inputEstimates) Then
        Exit Function
    End If
        
    'Copy the arrays to prevent modification
    Dim copiedEstimates() As Double
    copiedEstimates = inputEstimates
    
    'Sort the arrays ascending
    Call Base.QuickSort(copiedEstimates, ceAscending)
    
    Dim axisSize As Long
    axisSize = UBound(copiedEstimates) + 1
    
    'Generate y values / prepare the axis to the estimates [0.0 to 0.1 equidistant]
    Dim propabilityAxis() As Double
    propabilityAxis = EbsUtils.CalcPropabilityAxis(axisSize)
    
    'Now call interpolateion algorithm
    interpolated = Utils.InterpolateArray(propabilityAxis, copiedEstimates, supportPoints)
        
    InterpolateEstimates = interpolated
End Function



Function CalcPropabilityAxis(axisSize As Long) As Double()
    'This function returns an array from 0 to 1 with n = axisSize values which have equal spacing
    '
    'Input args:
    '  axisSize:               Size of elements one whishes to generate equidistant axis point from [0.0 to 1.0] for
    '
    'Output args:
    '  CalcPropabilityAxis:    The equidistant points

    Dim propabilityAxis() As Double
    CalcPropabilityAxis = propabilityAxis
    
    'Check args
    If axisSize < 1 Then Exit Function
    
    ReDim propabilityAxis(axisSize - 1)
    
    Dim propIdx As Integer
    For propIdx = 0 To axisSize - 1
        propabilityAxis(propIdx) = propIdx / (CDbl(axisSize) - 1)
    Next propIdx
    
    CalcPropabilityAxis = propabilityAxis
End Function



Function GetMonteCarloTimeEstimates(userEstimate As Double, velocityPool() As Double, pickCount As Integer) As Double()
    'Monte Carlo function to get random estimates. The function randomly picks from the passed velocity pool and returns
    'the estimates after a simple division. [1] 'user estimate'-> (ickCount) 'monte carlo estimates'
    '
    'Input args:
    '  userEstimate:   One estimate for which many estimates are generated
    '  velocityPool:   A pool of velocities for a user
    '  pickCount:      How many values should be picked?
    '
    'Output args:
    '  InterpolateEstimates: The interpolated values. Can be more or less than the specified input values. Be careful with extrapolation (works but
    '  can result in unreliable data)
    
    'Use Monte Carlo method here
    Dim pickedIndex As Integer
    Dim estimateIdx As Integer
    
    Dim pickedVelocity As Double
    Dim monteCarloEstimates() As Double
    ReDim monteCarloEstimates(pickCount - 1)
    
    For estimateIdx = 0 To pickCount - 1
        'Gen random index
        pickedIndex = EbsUtils.GenRandomIndex(UBound(velocityPool))
        pickedVelocity = velocityPool(pickedIndex)
        monteCarloEstimates(estimateIdx) = userEstimate / pickedVelocity 'user est: 5.00 / velo: 0.5 = 10.00, low velocity = long time
    Next estimateIdx
    
    GetMonteCarloTimeEstimates = monteCarloEstimates
End Function



Function CalcRemainingTime(userEstimate As Double, elapsedTime As Double) As Double
    'The remaining time is the difference of the time estimate and elapsed time.
    'If time estimate is too small the difference gets cut down to zero as no negative time estimates are allowed
    '
    'Input args:
    '  userEstimate:       The user's estimate
    '  elapsedTime:        The time the user already spent on the task
    '
    'Output args:
    '  CalcRemainingTime:  The time needed to finish the task (forecast). Limit to zero to prohibit negative values
    
    CalcRemainingTime = Base.Max(userEstimate - elapsedTime, 0)
End Function



Function GetPropabilityChartSettings(sheet As Worksheet, _
    ByRef modeSetting As PropabilityChartMode, ByRef scaleSetting As PropabilityChartScale)
    
    'The remaining time is the difference of the time estimate and elapsed time.
    'If time estimate is too small the difference gets cut down to zero as no negative time estimates are allowed
    '
    'Input args:
    '  sheet:          The user's ebs sheet
    '
    'Output args:
    '  modeSetting:    Mode is what the user wants to see
    '  scaleSetting:   Time (h) or date (d) timescale setting
    
    Dim modeVal As String
    Dim scaleVal As String
    
    modeVal = Utils.GetSingleDataCellVal(sheet, Constants.EBS_PROP_CHART_MODE_HEADER)
    scaleVal = Utils.GetSingleDataCellVal(sheet, Constants.EBS_PROP_CHART_SCALING_HEADER)
    
    'Select enum values according to the strings entered in the cell
    Select Case modeVal
        Case "Last"
            modeSetting = ceChartModeLast
        Case "Last 100 days"
            modeSetting = ceChartModeLastHundred
        Case "All"
            modeSetting = ceChartModeAll
    End Select
    
    Select Case scaleVal
        Case "Time"
            scaleSetting = ceChartScaleTime
        Case "Date"
            scaleSetting = ceChartScaleDate
    End Select
End Function



Function PrintPropabilityChart(sheet As Worksheet)

    'The function prepares and prints the main propability chart on ebs sheet. The propability chart displays the accumulated estimates
    'for the last ebs run, an overview of the remaining time estimates for the last n days (to see stockpiling of tasks) in different scales
    'time (h) or date (d)
    '
    'Input args:
    '  sheet:          The user's ebs sheet
    
    'First: Gather data
    'Second: Add series to chart and format style
    
    Dim mode As PropabilityChartMode
    Dim sca As PropabilityChartScale
    
    'Read axis type (date / time) and mode to use
    Call EbsUtils.GetPropabilityChartSettings(sheet, mode, sca)
    
    'At max three datasets are displayed (currently)
    Dim x1() As Double
    Dim x2() As Double
    Dim x3() As Double
    
    Dim y1() As Double
    Dim y2() As Double
    Dim y3() As Double
    
    Dim chartSupPoints() As Double
    chartSupPoints = Utils.CopyVarArrToDoubleArr(Constants.EBS_HIGHLIGHT_PROPABILITIES)
    
    If mode = PropabilityChartMode.ceChartModeLast Then
        Call EbsUtils.GetDataForLastRunGraph(sheet, mode, sca, x1, y1, x2, y2)
        
        'Check for the read datasets: Are all two sets available?
        If sca = PropabilityChartScale.ceChartScaleTime Then
            If Not Base.IsArrayAllocated(x1) Or _
                Not Base.IsArrayAllocated(y1) Or _
                Not Base.IsArrayAllocated(x2) Or _
                Not Base.IsArrayAllocated(y2) Then Exit Function
        ElseIf sca = PropabilityChartScale.ceChartScaleDate Then
            If Not Base.IsArrayAllocated(x1) Or _
                Not Base.IsArrayAllocated(y1) Then Exit Function
        End If
        
    ElseIf mode = PropabilityChartMode.ceChartModeLastHundred Or mode = ceChartModeAll Then
        Call EbsUtils.GetDataForLongtimeGraph(sheet, mode, sca, chartSupPoints, x1, y1, y2, y3)
        'Check for the read datasets: Are all three sets with same x-axis available?
        If Not Base.IsArrayAllocated(x1) Or Not Base.IsArrayAllocated(y1) Or _
            Not Base.IsArrayAllocated(y2) Or Not Base.IsArrayAllocated(y3) Then Exit Function
        x2 = x1
        x3 = x1
        
    End If
    
    'Get the chart and clear
    Dim propabilityChart As Chart
    Set propabilityChart = sheet.ChartObjects(Constants.EBS_PROP_CHART_INDEX).Chart
    propabilityChart.ChartArea.ClearContents
   
    'Set all the data series
    Dim seriees As Series
    
    'The first series will always be set
    propabilityChart.SeriesCollection.NewSeries
    Set seriees = propabilityChart.SeriesCollection(1)
    
    seriees.XValues = x1
    seriees.Values = y1
    
    If (mode = ceChartModeLast And sca = PropabilityChartScale.ceChartScaleTime) Or _
        mode = PropabilityChartMode.ceChartModeLastHundred Or _
        mode = PropabilityChartMode.ceChartModeAll Then
        
        'The interpolated series will be set
        propabilityChart.SeriesCollection.NewSeries
        Set seriees = propabilityChart.SeriesCollection(2)
        seriees.XValues = x2
        seriees.Values = y2
    End If
    
    If mode = PropabilityChartMode.ceChartModeLastHundred Or mode = PropabilityChartMode.ceChartModeAll Then
        propabilityChart.SeriesCollection.NewSeries
        Set seriees = propabilityChart.SeriesCollection(3)
        seriees.XValues = x3
        seriees.Values = y3
    End If
    
    Dim accentColor As Long
    Dim commonColor As Long
    Dim lightColor As Long
    
    accentColor = SettingUtils.GetColors(ceAccentColor)
    commonColor = SettingUtils.GetColors(ceCommonColor)
    lightColor = SettingUtils.GetColors(ceLightColor)
    
    'Now format the series points and connecting lines
    If mode = PropabilityChartMode.ceChartModeLastHundred Or mode = PropabilityChartMode.ceChartModeAll Then
        Set seriees = propabilityChart.SeriesCollection(1)
        seriees.name = Format(chartSupPoints(0), "#0%")
        With seriees
            .Format.Line.Weight = 1.25
            .Format.Line.Visible = msoTrue
            .Format.Line.ForeColor.RGB = commonColor
            '.Format.Line.ForeColor.Brightness = -0.1
            .Format.Line.transparency = 0
            .MarkerBackgroundColor = lightColor
        End With
        
        Set seriees = propabilityChart.SeriesCollection(2)
        seriees.name = Format(chartSupPoints(1), "#0%")
        With seriees
            .Format.Line.Weight = 1.25
            .Format.Line.Visible = msoTrue
            .Format.Line.ForeColor.RGB = accentColor
            .Format.Line.transparency = 0
            .MarkerBackgroundColor = lightColor
        End With
        
        Set seriees = propabilityChart.SeriesCollection(3)
        seriees.name = Format(chartSupPoints(2), "#0%")
        With seriees
            .Format.Line.Weight = 1.25
            .Format.Line.Visible = msoTrue
            .Format.Line.ForeColor.RGB = commonColor
            .Format.Line.transparency = 0
            .MarkerBackgroundColor = lightColor
        End With
        
    ElseIf mode = PropabilityChartMode.ceChartModeLast Then
        If sca = PropabilityChartScale.ceChartScaleTime Then
            Set seriees = propabilityChart.SeriesCollection(1)
            seriees.name = Format("Last task prop. dist.")
            With seriees
                .Format.Line.Weight = 1.25
                .Format.Line.Visible = msoTrue
                .Format.Line.ForeColor.RGB = accentColor
                .Format.Line.transparency = 0
                .MarkerBackgroundColor = lightColor
            End With
            
            Set seriees = propabilityChart.SeriesCollection(2)
            seriees.name = Format("Interpolated dist.")
            With seriees
                .Format.Line.Weight = 1.25
                .Format.Line.Visible = msoTrue
                .Format.Line.ForeColor.RGB = commonColor
                .Format.Line.transparency = 0
                .MarkerBackgroundColor = lightColor
            End With
                
        ElseIf sca = PropabilityChartScale.ceChartScaleDate Then
            Set seriees = propabilityChart.SeriesCollection(1)
            seriees.name = Format("Last task prop. dist.")
            With seriees
                .Format.Line.Weight = 1.25
                .Format.Line.Visible = msoTrue
                .Format.Line.ForeColor.RGB = accentColor
                .Format.Line.transparency = 0
                .MarkerBackgroundColor = lightColor
            End With
        End If
    End If
    
    'Format the axis and it's label
    
    Dim axv As Axis 'axv = axis value = y
    Dim axc As Axis 'axc = axis category = x
    
    Set axv = propabilityChart.Axes(XlAxisType.xlValue)
    Set axc = propabilityChart.Axes(XlAxisType.xlCategory)
    
    If mode = PropabilityChartMode.ceChartModeLast Then
        axv.MaximumScale = 1
        axv.MinimumScale = 0
        axv.TickLabels.NumberFormat = "0%"
        axv.AxisTitle.Characters.Text = "Propability"
        
        Select Case sca
            Case PropabilityChartScale.ceChartScaleTime
                axc.TickLabels.NumberFormat = "0,00"
                axc.AxisTitle.Characters.Text = "Est. finish time in h"
            Case PropabilityChartScale.ceChartScaleDate
                axc.TickLabels.NumberFormat = "dd/mm"
                axc.AxisTitle.Characters.Text = "Est. finish date"
        End Select
        
    ElseIf mode = PropabilityChartMode.ceChartModeLastHundred Or mode = PropabilityChartMode.ceChartModeAll Then
        axv.MaximumScaleIsAuto = True
        axv.MinimumScaleIsAuto = True
        
        axc.TickLabels.NumberFormat = "dd/mm"
        axc.AxisTitle.Characters.Text = "EBS estimation time"
        
        Select Case sca
            Case PropabilityChartScale.ceChartScaleTime
                axv.TickLabels.NumberFormat = "0,00"
                axv.AxisTitle.Characters.Text = "Est. finish time in h"
                
            Case PropabilityChartScale.ceChartScaleDate
                axv.TickLabels.NumberFormat = "dd/mm"
                axv.AxisTitle.Characters.Text = "Est. finish date"
        End Select
    End If
End Function



Function GetDataForLongtimeGraph(sheet As Worksheet, mode As PropabilityChartMode, sca As PropabilityChartScale, chartSupPoints() As Double, _
    ByRef x() As Double, _
    ByRef y1() As Double, _
    ByRef y2() As Double, _
    ByRef y3() As Double)
    
    'This function fetches the data for the project's long time graph showing ebs run data development. With the data one can
    'see the project finish time change to evaluate stockpiling of tasks
    '
    'Input args:
    '  sheet:          The user's ebs sheet
    '  mode:           The selected mode. Selects which data timespan to fetch
    '  sca:            Axis scaling. Selects whether to use h or date scaling
    '  chartSupPoints: The propabilities to show in the chart (low propability, mid propability and high propability, [0.15, 0.50, 0.85] for example
    '                  Currently only three support point values are allowed (three output datasets)
    '
    'Output args:
    '  x:              The x axis values
    '  y1:             The y values of the 'low'propability
    '  y2:             The y values of the 'mid propability
    '  y3:             The y values of the 'high'propability
        
    Dim minDate As Date
    
    'Select whether to filter for date or not (date = 0)
    Select Case mode
        Case PropabilityChartMode.ceChartModeLastHundred
            'Filter range for dates later than Now - 100 days
            minDate = Now - 100
        Case PropabilityChartMode.ceChartModeAll
            minDate = 0
    End Select
     
    Dim filteredCells As Range 'x values are stored here (dates of ebs runs)
    Set filteredCells = EbsUtils.GetEbsMainListColumn(sheet, Constants.EBS_RUN_DATE_HEADER, ceData)
    
    'Find all cells with a date later than 'minDate'
    Set filteredCells = Base.FindAll(filteredCells, minDate, , ceDoubleBigger)
    
    If filteredCells Is Nothing Then
        'Found no data to display
        Exit Function
    End If

    'Debug info
    'Debug.Print "Range of last 100 day dates: " & xValRange.Address
            
    Dim supPointsRange As Range
    Dim estRange As Range 'Can be time (h) or date (d) estimates
    Dim supPoints() As Double
    Dim estimates() As Double
                  
    'Get the column with data
    Set supPointsRange = EbsUtils.GetEbsMainListColumn(sheet, Constants.EBS_SUPPORT_POINT_HEADER, ceData)
    
    Select Case sca
        Case PropabilityChartScale.ceChartScaleTime
            Set estRange = EbsUtils.GetEbsMainListColumn(sheet, Constants.EBS_TIME_ESTIMATES_HEADER, ceData)
        Case PropabilityChartScale.ceChartScaleDate
            Set estRange = EbsUtils.GetEbsMainListColumn(sheet, Constants.EBS_DATE_ESTIMATES_HEADER, ceData)
    End Select
 
            
    'Reserve storage in the data axis
    Dim dataCount As Long
    dataCount = filteredCells.Count
    
    ReDim x(dataCount - 1)
    ReDim y1(dataCount - 1)
    ReDim y2(dataCount - 1)
    ReDim y3(dataCount - 1)
            
    Dim datasetCell As Range
    Dim datasetIdx As Long
    Dim curSupPointsVal As String
    Dim curTimeEstsVal As String
    Dim chartTimeEsts() As Double
            
    datasetIdx = 0
        
    For Each datasetCell In filteredCells
        'Cycle through all the filteredCell: Points of time at which ebs was run and add datapoints
        curTimeEstsVal = Base.IntersectN(datasetCell.EntireRow, estRange).Value
        
        'Chart support points may vary over time. Read the support points here from the data
        curSupPointsVal = Base.IntersectN(datasetCell.EntireRow, supPointsRange).Value
        supPoints = Utils.CopyVarArrToDoubleArr(Utils.DeserializeArray(curSupPointsVal))
        
        Select Case sca
            Case PropabilityChartScale.ceChartScaleTime
                estimates = Utils.CopyVarArrToDoubleArr(Utils.DeserializeArray(curTimeEstsVal))
            Case PropabilityChartScale.ceChartScaleDate
                estimates = Utils.CopyVarArrToDoubleArr(Utils.CopyVarArrToDateArr(Utils.DeserializeArray(curTimeEstsVal)))
        End Select
                                
        If Not Base.IsArrayAllocated(estimates) Then Exit Function
        
        'Crop the estimates to the chart support points
        chartTimeEsts = Utils.CopyVarArrToDoubleArr(Utils.InterpolateArray(supPoints, estimates, chartSupPoints))
                
        'Write data to axis
        x(datasetIdx) = CDbl(datasetCell.Value)
        y1(datasetIdx) = chartTimeEsts(0)
        y2(datasetIdx) = chartTimeEsts(1)
        y3(datasetIdx) = chartTimeEsts(2)
        datasetIdx = datasetIdx + 1
    Next datasetCell
    'Sort the datasets by the ebs run date
    Call Base.QuickSort(x, ceAscending, , , y1, y2, y3)
End Function



Function GetDataForLastRunGraph(sheet As Worksheet, mode As PropabilityChartMode, sca As PropabilityChartScale, _
    ByRef x1() As Double, _
    ByRef y1() As Double, _
    ByRef x2() As Double, _
    ByRef y2() As Double)
    
    'This function fetches in depth data for the 'last'/ 'current'ebs run. The data returned can be displayed to give a visual impression
    'of the estimates for the unfinished / queued tasks. Additionally to the full dataset interpolated data is shown as well to prove that
    'the interpolation works
    '
    'Input args:
    '  sheet:          The user's ebs sheet
    '  mode:           The selected mode. Selects which data timespan to fetch
    '  sca:            Axis scaling. Selects whether to use h or date scaling
    '
    'Output args:
    '  x1:             The x axis values, time after or dates on which a task is finished
    '  y1:             The propability of a task being finished at time / date (x)
    '  x2:             The interpolated x axis values
    '  y2:             The interpolated y axis values
    
    Dim x1Cells As Range
    Dim x2Cells As Range
    Dim y1Cells As Range
    Dim y2Cells As Range
    
    If sca = PropabilityChartScale.ceChartScaleTime Then
        'Show accumulated times (h) and interpolated times (h) of the accumulated times for the last task
                    
        'First x-axis: accumulated time
        Set x1Cells = EbsUtils.GetRunDataListColumn(sheet, Constants.EBS_RUNDATA_ACCUMULATED_TIME_POOL_HEADER, ceData)
        Set x1Cells = Utils.GetBottomRightCell(x1Cells)
        x1 = Utils.CopyVarArrToDoubleArr(Utils.DeserializeArray(x1Cells.Value))
               
        If Not Base.IsArrayAllocated(x1) Then Exit Function
        
        'Sort to ascending hours
        Call Base.QuickSort(x1, ceAscending)
        
        'First y-axis: propabilities for accumulated time. Do not read y val from table - generate the propability axis for the x axis here
        y1 = EbsUtils.CalcPropabilityAxis(UBound(x1) + 1)
        
        If Not Base.IsArrayAllocated(y1) Then Exit Function
                    
        'Second x-axis: interpolated accumulated time
        Set x2Cells = EbsUtils.GetRunDataListColumn(sheet, Constants.EBS_RUNDATA_INTERPOLATED_TIME_HEADER, ceData)
        Set x2Cells = Utils.GetBottomRightCell(x2Cells)
        x2 = Utils.CopyVarArrToDoubleArr(Utils.DeserializeArray(x2Cells.Value))
        
        If Not Base.IsArrayAllocated(x2) Then Exit Function
                    
        'Second y-axis: propabilities for interpolated accumulated time
        Set y2Cells = EbsUtils.GetRunDataListColumn(sheet, Constants.EBS_SUPPORT_POINT_HEADER, ceData)
        Set y2Cells = Utils.GetBottomRightCell(y2Cells)
        y2 = Utils.CopyVarArrToDoubleArr(Utils.DeserializeArray(y2Cells.Value))
        
        If Not Base.IsArrayAllocated(y2) Then Exit Function
                    
    ElseIf sca = PropabilityChartScale.ceChartScaleDate Then
        'Show interpolated dates (d)
        'First x-axis: interpolated dates
        Set x1Cells = EbsUtils.GetRunDataListColumn(sheet, Constants.EBS_RUNDATA_INTERPOLATED_DATES_HEADER, ceData)
        Set x1Cells = Utils.GetBottomRightCell(x1Cells)
        
        If x1Cells Is Nothing Then Exit Function
        
        x1 = Utils.CopyVarArrToDoubleArr(Utils.CopyVarArrToDateArr(Utils.DeserializeArray(x1Cells.Value)))
        
        If Not Base.IsArrayAllocated(x1) Then Exit Function
        
        Set y1Cells = EbsUtils.GetRunDataListColumn(sheet, Constants.EBS_SUPPORT_POINT_HEADER, ceData)
        Set y1Cells = Utils.GetBottomRightCell(y1Cells)
        y1 = Utils.CopyVarArrToDoubleArr(Utils.DeserializeArray(y1Cells.Value))
        
    End If
End Function



Function CalcExponentialTransparencyCurve(valCount As Integer) As Double()
    'Return transparency values from 0.0 (full visibility) to 0.9 following an exponential curve
    'to stress the fully visible data series of a chart against the other data series
    '
    '
    'Input args:
    '  valCount:                           Count of data series / elements to apply a visibility to
    '
    'Output args:
    '  CalcExponentialTransparencyCurve:   The transparency values starting with high transparency / low visibility
    
    'Init output
    Dim transparencyVals() As Double
    CalcExponentialTransparencyCurve = transparencyVals
    
    'Check args
    If valCount < 1 Then Exit Function
    
    ReDim transparencyVals(0 To valCount - 1)
    
    Dim transpIdx As Integer
    For transpIdx = 0 To valCount - 1
        If valCount = 1 Then
            transparencyVals(0) = 0 '0% transparency
        Else
            transparencyVals(transpIdx) = 0.9 * Exp(Log(0.1 / 0.9) / (valCount - 1) * transpIdx)
        End If
    Next transpIdx
    
    CalcExponentialTransparencyCurve = transparencyVals
End Function



Function GetLatestEbsRun(sheet As Worksheet, Optional ByRef runDate As Date) As String

    'This function searches for all EBS run entries in the main list and returns the hash with the latest run date
    '
    'Input args:
    '  sheet:      The ebs sheet you want to examinte
    '
    'Output args:
    '  runDate:    The date of the latest ebs run
    
    'Init output
    GetLatestEbsRun = ""
    runDate = CDate(0)
    
    'Check args
    If sheet Is Nothing Then Exit Function
    
    Dim eHashCells As Range
    Set eHashCells = EbsUtils.GetEbsMainListColumn(sheet, Constants.EBS_HASH_HEADER, ceData)
    
    If Not eHashCells Is Nothing Then
        Dim runCount As Long
        runCount = eHashCells.Count
        
        If runCount > 0 Then
            Dim dateCells As Range
            Set dateCells = EbsUtils.GetEbsMainListColumn(sheet, Constants.EBS_RUN_DATE_HEADER, ceData)
            
            Dim dates() As Date
            Dim hashes() As String
        
            ReDim dates(0 To runCount - 1)
            ReDim hashes(0 To runCount - 1)
            
            Dim dIdx As Long
            'Get hash cells and dates
            For dIdx = 0 To runCount - 1

                dates(dIdx) = CDate(dateCells(dIdx + 1).Value)
                hashes(dIdx) = eHashCells(dIdx + 1).Value
            Next dIdx
            
            'Sort dates descending and order hashCells accordingly
            Call Base.QuickSort(dates, ceDescending, , , hashes)
            
            'Return eHash and run date
            runDate = dates(0)
            GetLatestEbsRun = hashes(0)
        End If
    End If
End Function



Function DeleteAllEbsSheets()
    'Delete all ebs sheets. This is a helping function currently not called in the program.

    Dim regex As New RegExp
    regex.Global = True
    regex.Pattern = Constants.EBS_SHEET_REGEX
    Dim sheet As Worksheet
    For Each sheet In ThisWorkbook.Worksheets
        If regex.Test(sheet.name) Then
            Application.DisplayAlerts = False
            sheet.Delete
            Application.DisplayAlerts = True
        End If
    Next sheet
End Function