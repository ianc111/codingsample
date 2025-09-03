* This code looks at a Qualtrics survey response dataset with suggested salary values and preference rankings for 8 candidates and attempts to adjust suspicious anomalies (possibly due to typos or not following instructions)

* Validate interview_yesno_q1 (Whether the candidate recieve and interview):
gen interview_flag = 0
replace interview_flag = 1 if !(inlist(lower(interview_yesno_q1), "yes", "no")) & !missing(interview_yesno_q1)

* Validate ranking_q1 (Preferences should be integers 1–8 and allowing repeats):
gen ranking_flag = 0
replace ranking_flag = 1 if missing(ranking_q1) | !inlist(real(ranking_q1), 1,2,3,4,5,6,7,8)

* Identify string salary variables
local salaryvars five_percent_q4 fifty_percent_q4 ninetyfive_percent_q4 salary_max_q3 salary_offer_q1
ds `salaryvars', has(type string)
local stringvars `r(varlist)'

* Fix ",00" but not ",000" (That final value should not exceed 500K, which is a reasonable upper bound)
gen comma_flag = 0
foreach var of local stringvars {
    gen tempvar_`var' = `var'
    replace tempvar_`var' = subinstr(tempvar_`var', ",00", "000", .) if strpos(tempvar_`var', ",00") & !strpos(tempvar_`var', ",000")
    destring tempvar_`var', gen(tempvar_d_`var') force
    replace `var' = tempvar_`var' if inrange(tempvar_d_`var', 10000, 500000)
    drop tempvar_`var' tempvar_d_`var'
    replace comma_flag = 1
}

* Fix suffixes and prefixes
gen prefixsuffix_flag = 0
foreach var of local stringvars {
    replace `var' = subinstr(`var', ",", "", .) if strpos(`var', ",")
    replace `var' = subinstr(`var', "K", "", .) if strpos(`var', "K")
    replace `var' = subinstr(`var', "k", "", .) if strpos(`var', "k")
    replace `var' = subinstr(`var', "$", "", .) if strpos(`var', "$")
    replace prefixsuffix_flag = 1
}

* Destring and change to type double
foreach var of local salaryvars {
    capture confirm string variable `var'
    if !_rc {
        destring `var', replace force
    }
    capture confirm variable `var'
    if !_rc {
        local vartype : type `var'
        if !inlist("`vartype'", "double", "float") {
            gen double __temp_`var' = `var'
            drop `var'
            rename __temp_`var' `var'
        }
    }
}

* The errors after this point should involve either transitivity or magnitude issues
* For example, recall that when I drop the suffix "K," 500K leads to a suggested salary of 500, which doesn't make sense
* I make the assumption that these salaries are largely supposed to be between 50K and 500K and anything atypically smaller is a mistake
* I do not correct large numbers and instead flag them

* Check salary ranges
gen smallnumber_flag = 0
foreach var of local salaryvars {
    replace `var' = `var' * 10000 if inrange(`var', 10, 49) & inrange(`var'*10000, 100000, 500000)
    replace smallnumber_flag = 1 if inrange(`var', 10, 49) & !inrange(`var'*10000, 100000, 500000)

    replace `var' = `var' * 1000 if inrange(`var', 50, 99) & inrange(`var'*1000, 50000, 99999)
    replace smallnumber_flag = 1 if inrange(`var', 50, 99) & !inrange(`var'*1000, 50000, 99999)

    replace `var' = `var' * 1000 if inrange(`var', 100, 499) & inrange(`var'*1000, 100000, 500000)
    replace smallnumber_flag = 1 if inrange(`var', 100, 499) & !inrange(`var'*1000, 100000, 500000)

    replace smallnumber_flag = 1 if inrange(`var', 500, 999)
}

* For the following step, fix values are less than 1/5 of median, but not less than 1/20, or between 5 to 20 times the median
* For example, if the value of an observation is "20000" but the average of the other values is "250000," that suggests that its value is likely supposed to be "200000"

gen magnitude_flag = 0
local median_loop_continue 1
while `median_loop_continue' {
    gen median_count = 0
    egen salary_median = rowmedian(`salaryvars')

    foreach var of local salaryvars {
        gen ratio_`var' = `var' / salary_median if `var' > 0 & salary_median > 0

        replace `var' = `var' * 10 if ratio_`var' <= 0.2 & ratio_`var' > 0.05
        replace `var' = `var' / 10 if ratio_`var' >= 5 & ratio_`var' < 20
        replace median_count = 1 if ((ratio_`var' <= 0.2 & ratio_`var' > 0.05) | (ratio_`var' >= 5 & ratio_`var' < 20))
        replace magnitude_flag = 1 if (ratio_`var' >= 20 | ratio_`var' <= 0.05)

        drop ratio_`var'
    }

    drop salary_median
    quietly summarize median_count
    if r(max) == 0 {
        local median_loop_continue 0
    }
    drop median_count
}

* For the following step, use transitivity to check that salary values align with rankings
* Check if observations with lower rankings are given much higher salaries, or observations with higher rankings are given much lower salaries

gen transitivity_flag = 0
local transitivity_loop_continue 1
gen ranknum = real(ranking_q1)
gen interview_bin = inlist(lower(interview_yesno_q1), "yes")

while `transitivity_loop_continue' {
    gen trans_count = 0
    sort uwid ranknum

    foreach var of local salaryvars {
        gen lv_`var' = .
        gen uv_`var' = .

        by uwid (ranknum): replace lv_`var' = `var'[_n-1] if _n > 1 & !missing(ranknum)
        by uwid (ranknum): replace uv_`var' = `var'[_n+1] if _n < _N & !missing(ranknum)

        gen lr_`var' = `var' / lv_`var' if lv_`var' > 0 & `var' > 0
        gen ur_`var' = `var' / uv_`var' if uv_`var' > 0 & `var' > 0

        gen ft_`var' = 0
        replace ft_`var' = 1 if lr_`var' >= 5 & lr_`var' < 20 & ranknum != 8
        replace ft_`var' = 1 if ur_`var' >= 5 & ur_`var' < 20 & ranknum != 1

        replace `var' = `var' * 10 if ft_`var' == 1
        replace trans_count = 1 if ft_`var' == 1

        replace transitivity_flag = 1 if lr_`var' >= 20 | ur_`var' >= 20

        drop lv_`var' uv_`var' lr_`var' ur_`var' ft_`var'
    }

    quietly summarize trans_count
    if r(max) == 0 {
        local trans_loop_continue = 0
    }
    drop trans_count
}

drop ranknum interview_bin
keep uwid std_name ///
	 interview_yesno_q1 ///
	 ranking_q1 ///
     five_percent_q4 ///
	 fifty_percent_q4 ///
	 ninetyfive_percent_q4 ///
     salary_max_q3 salary_offer_q1 ///
     interview_flag ///
	 ranking_flag ///
	 comma_flag ///
	 prefixsuffix_flag ///
     smallnumber_flag ///
	 magnitude_flag ///
	 transitivity_flag
save "cleanedTransformedCandidateEvals.dta", replace
